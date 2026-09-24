//
//  RemoteScreenHost.swift
//  OpenBeam
//
//  The host side of one remote screen session (SCREEN-PROTOCOL.md): listens for
//  the viewer's two connections, streams the captured display over one and reads
//  input from the other. One instance serves one session and is then discarded.
//

import AppKit
import CryptoKit
import Foundation
import SystemConfiguration
import os

private let hostLog = Logger(subsystem: "com.openbeam.remotescreen", category: "host")

/// Where the viewer's input goes.
protocol RemoteInputSink: AnyObject {
    /// The display pointer positions are normalized to, when the session switches.
    func use(display: CGDirectDisplayID)
    func inject(_ event: InputEventMessage)
    /// Lets go of every key and button the viewer is holding down.
    func releaseAll()
}

final class RemoteScreenHost: @unchecked Sendable {
    /// The wire reasons of `screen.stop`.
    enum EndReason: String {
        case user
        case revoked
        case displayLost = "display_lost"
        case error
        case other

        /// Ended on purpose on the host's side: a viewer should not try to come back.
        var isFinal: Bool { self == .user || self == .revoked }
    }

    /// Called once, off the main thread, when the session ends for any reason.
    var onEnded: ((EndReason) -> Void)?
    /// Off the main thread, whenever the displays or the shared one change.
    var onDisplaysChanged: (([ScreenDisplayInfo], CGDirectDisplayID) -> Void)?
    private(set) var sessionID = Data()

    private let inputSink: RemoteInputSink?  // held here: nothing else needs to keep it alive
    private let capture = RemoteScreenCapture()
    private var keys: ScreenSessionKeys?
    private var displayID: CGDirectDisplayID = 0
    private var endpoints: [ScreenOfferPayload.Endpoint] = []  // as offered, to tell which link a viewer used
    private var minFrameIntervalNs: UInt64 = 0
    private var request: ScreenRequestPayload?

    // Capture lifecycle across display changes: controlQueue only.
    private let controlQueue = DispatchQueue(label: "com.openbeam.remotescreen.host-control")
    private var capturing = false
    private var restartWork: DispatchWorkItem?
    private var displayMissingSince: Date?
    private var captureFailures = 0
    private var watchingDisplays = false
    /// How long a display may be gone (a monitor waking, an input switching
    /// back) before the session gives up on it.
    private static let displayGrace: TimeInterval = 15
    private var watchdog: DispatchSourceTimer?

    private final class PendingFrame {
        let buffer: CVPixelBuffer
        let captureHostNs: UInt64
        var dirtyRects: [CGRect]?  // nil: send it whole
        let inputSeq: UInt64
        let inputHostNs: UInt64

        init(_ frame: RemoteScreenCapture.Frame, input: (seq: UInt64, hostNs: UInt64)) {
            buffer = frame.buffer
            captureHostNs = frame.captureHostNs
            dirtyRects = frame.dirtyRects
            inputSeq = input.seq
            inputHostNs = input.hostNs
        }
    }

    // Guarded by `cond`.
    private let cond = NSCondition()
    private var ended = false
    private var started = false
    private var listenFD: Int32 = -1
    private var videoFD: Int32 = -1
    private var inputFD: Int32 = -1
    private var inputReceiver: RecordReceiver?
    private var pending: PendingFrame?
    private var needWhole = true
    private var lastInput: (seq: UInt64, hostNs: UInt64) = (0, 0)
    private var lastActivityNs: UInt64 = 0
    private var stats = Stats()

    private struct Stats {
        var captured = 0, sent = 0, whole = 0, merged = 0, bytes = 0, sendNs: UInt64 = 0
    }

    init(inputSink: RemoteInputSink?) {
        self.inputSink = inputSink
    }

    // MARK: - Session setup

    /// Starts listening for the viewer and returns the offer to send it.
    func open(request: ScreenRequestPayload, hostPeerID: String,
              display: CGDirectDisplayID = CGMainDisplayID()) throws -> ScreenOfferPayload {
        // The display the viewer asked for, if this Mac still has it.
        displayID = request.displayID.flatMap { CGDisplayIsOnline($0) != 0 ? $0 : nil } ?? display
        inputSink?.use(display: displayID)
        self.request = request
        let captureSize = RemoteScreenCapture.fittedSize(display: displayID, maxWidth: request.maxWidth, maxHeight: request.maxHeight)
        if let fps = request.maxFPS, fps > 0 { minFrameIntervalNs = 1_000_000_000 / UInt64(fps) }

        let key = SymmetricKey(size: .bits256)
        sessionID = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        keys = ScreenSessionKeys(key: key, sessionID: sessionID)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else {
            let code = errno
            close(fd)
            throw RemoteScreenError.io("listen", code)
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        let endpoints = RemoteScreenEndpoints.current()
        guard !endpoints.isEmpty else {
            close(fd)
            throw RemoteScreenError.protocolViolation("no network address to offer")
        }

        cond.lock()
        listenFD = fd
        cond.unlock()
        Thread.detachNewThread { self.acceptLoop(fd) }
        DispatchQueue.global().asyncAfter(deadline: .now() + RemoteScreen.bindTimeout) {
            self.cond.lock()
            let late = !self.started && !self.ended
            self.cond.unlock()
            if late {
                hostLog.error("viewer did not bind within \(RemoteScreen.bindTimeout, privacy: .public) s")
                self.end(.error)
            }
        }

        let mode = CGDisplayCopyDisplayMode(displayID)
        let name = Self.name(of: displayID)
        self.endpoints = endpoints
        hostLog.info("offering session on port \(port, privacy: .public), \(captureSize.width, privacy: .public)×\(captureSize.height, privacy: .public), endpoints \(endpoints.map { "\($0.link) \($0.address)" }.joined(separator: ", "), privacy: .public)")
        return ScreenOfferPayload(requestID: request.requestID,
                                  sessionID: sessionID,
                                  key: key.withUnsafeBytes { Data($0) },
                                  port: port,
                                  endpoints: endpoints,
                                  display: .init(name: name ?? "Display", width: captureSize.width,
                                                 height: captureSize.height, refreshHz: mode?.refreshRate ?? 0),
                                  originID: hostPeerID)
    }

    /// Accepts until both channels are bound or the session ends. Polls so that
    /// `end` never has to close a socket another thread is blocked on.
    private func acceptLoop(_ fd: Int32) {
        while true {
            cond.lock()
            let done = ended || started
            cond.unlock()
            if done { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 250) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            Thread.detachNewThread { self.bindConnection(client) }
        }
        close(fd)
        cond.lock()
        if listenFD == fd { listenFD = -1 }
        cond.unlock()
    }

    /// Reads the preamble and BIND; adopts the connection if both check out.
    private func bindConnection(_ fd: Int32) {
        setSocketOption(fd, IPPROTO_TCP, TCP_NODELAY, 1)
        setSocketOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
        setSocketOption(fd, SOL_SOCKET, SO_SNDBUF, 16 << 20)
        setReceiveTimeout(fd, seconds: Int(RemoteScreen.bindTimeout))
        do {
            var preamble = [UInt8](repeating: 0, count: RemoteScreen.preambleSize)
            try preamble.withUnsafeMutableBytes { try readExactly(fd, $0) }
            guard Array(preamble[0..<4]) == RemoteScreen.preambleMagic else {
                throw RemoteScreenError.protocolViolation("bad preamble")
            }
            guard preamble[4] == RemoteScreen.version else {
                throw RemoteScreenError.protocolViolation("unsupported version \(preamble[4])")
            }
            guard let channel = RemoteScreen.Channel(rawValue: preamble[5]), let keys else {
                throw RemoteScreenError.protocolViolation("unknown channel \(preamble[5])")
            }
            let receiver = RecordReceiver(fd: fd, key: keys.viewerToHost(channel))
            guard let bind = BindMessage(try receiver.read(20)), bind.channel == channel, bind.sessionID == sessionID else {
                throw RemoteScreenError.protocolViolation("bad BIND")
            }
            setReceiveTimeout(fd, seconds: 0)

            cond.lock()
            let taken = ended || (channel == .video ? videoFD : inputFD) >= 0
            if !taken {
                if channel == .video { videoFD = fd } else { inputFD = fd; inputReceiver = receiver }
            }
            let ready = !taken && videoFD >= 0 && inputFD >= 0
            if ready { started = true }
            cond.unlock()
            if taken {
                close(fd)
                return
            }
            hostLog.info("\(channel == .video ? "video" : "input", privacy: .public) channel bound")
            if ready { startStreaming() }
        } catch {
            hostLog.error("rejected connection: \(String(describing: error), privacy: .public)")
            close(fd)
        }
    }

    // MARK: - Streaming

    private func startStreaming() {
        cond.lock()
        lastActivityNs = monotonicNs()
        let fd = videoFD
        cond.unlock()
        // Raw pixels are for Thunderbolt. A viewer that reached us some other way
        // (the cable came out, and it reconnected over Ethernet or Wi-Fi) gets
        // half the size at no more than 60 fps, which those links can carry.
        let link = link(ofLocalAddressOf: fd)
        if link != "thunderbolt" {
            minFrameIntervalNs = max(minFrameIntervalNs, 1_000_000_000 / 60)
            hostLog.info("viewer is on \(link, privacy: .public): half size, 60 fps at most")
        }
        capture.onFrame = { [weak self] frame in self?.submit(frame) }
        capture.onStop = { [weak self] in
            // ScreenCaptureKit gives up on a display that changes under it; the
            // session pauses and tries again rather than ending.
            self?.controlQueue.async { self?.captureInterrupted() }
        }
        let sender = Thread { self.sendLoop() }
        sender.qualityOfService = .userInteractive
        sender.start()
        let reader = Thread { self.inputLoop() }
        reader.qualityOfService = .userInteractive
        reader.start()
        startWatchdog()
        CGDisplayRegisterReconfigurationCallback(Self.displaysReconfigured, Unmanaged.passUnretained(self).toOpaque())
        controlQueue.async {
            self.watchingDisplays = true
            if link != "thunderbolt", let request = self.request {
                self.request?.maxWidth = request.maxWidth / 2
                self.request?.maxHeight = request.maxHeight / 2
            }
            self.startCapture()
        }
    }

    // MARK: - Display changes

    /// Called for each display before and after macOS reconfigures them.
    private static let displaysReconfigured: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo else { return }
        let host = Unmanaged<RemoteScreenHost>.fromOpaque(userInfo).takeUnretainedValue()
        let beginning = flags.contains(.beginConfigurationFlag)
        host.controlQueue.async { host.displaysChanging(beginning: beginning) }
    }

    /// Capture pauses while macOS rearranges displays and resumes a second after
    /// the last change: capturing a display mid-change gains nothing, and
    /// WindowServer is at its most fragile then.
    private func displaysChanging(beginning: Bool) {
        guard watchingDisplays, !isEnded else { return }
        if beginning {
            restartWork?.cancel()
            if capturing {
                hostLog.info("displays reconfiguring: capture paused")
                capture.stop()
                capturing = false
            }
        } else {
            scheduleCapture(after: 1)
        }
    }

    private func captureInterrupted() {
        capturing = false
        scheduleCapture(after: 1)
    }

    private func scheduleCapture(after seconds: TimeInterval) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startCapture() }
        restartWork = work
        controlQueue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// (Re)starts capture at the size the display's current mode gives, or waits
    /// for a display that is gone. controlQueue only.
    private func startCapture() {
        guard !isEnded, !capturing, let request else { return }
        guard CGDisplayIsOnline(displayID) != 0, CGDisplayIsActive(displayID) != 0 else {
            let since = displayMissingSince ?? Date()
            displayMissingSince = since
            if Date().timeIntervalSince(since) > Self.displayGrace {
                end(.displayLost)
            } else {
                scheduleCapture(after: 1)
            }
            return
        }
        displayMissingSince = nil
        let size = RemoteScreenCapture.fittedSize(display: displayID, maxWidth: request.maxWidth, maxHeight: request.maxHeight)
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        Task {
            do {
                try await capture.start(display: displayID, width: size.width, height: size.height)
            } catch {
                failure = error
            }
            done.signal()
        }
        done.wait()
        if let failure {
            captureFailures += 1
            hostLog.error("capture failed (\(self.captureFailures, privacy: .public)): \(failure.localizedDescription, privacy: .public)")
            if captureFailures >= 3 { end(.error) } else { scheduleCapture(after: 1) }
            return
        }
        captureFailures = 0
        capturing = true
        cond.lock()
        needWhole = true  // the viewer's picture may be stale or the wrong size
        cond.unlock()
        onDisplaysChanged?(Self.displays(), displayID)
    }

    /// Switches the session to another display, keeping it running. controlQueue.
    func select(display id: CGDirectDisplayID) {
        controlQueue.async {
            guard !self.isEnded, id != self.displayID, CGDisplayIsOnline(id) != 0,
                  Self.displays().contains(where: { $0.id == id })
            else { return }
            hostLog.info("switching to display \(id, privacy: .public)")
            self.displayID = id
            self.displayMissingSince = nil
            self.inputSink?.use(display: id)
            if self.capturing {
                self.capture.stop()
                self.capturing = false
            }
            self.restartWork?.cancel()
            self.startCapture()
        }
    }

    /// The displays this Mac can share, as `screen.displays` lists them:
    /// active ones, each mirror set once.
    static func displays() -> [ScreenDisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { id in
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { return nil }
            let bounds = CGDisplayBounds(id)
            let pixels = RemoteScreenCapture.pixelSize(of: id)
            return ScreenDisplayInfo(id: id, name: name(of: id), width: pixels.width, height: pixels.height,
                                     x: bounds.minX, y: bounds.minY, pointWidth: bounds.width, pointHeight: bounds.height,
                                     refreshHz: CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0, main: CGDisplayIsMain(id) != 0)
        }
    }

    private static func name(of id: CGDirectDisplayID) -> String {
        NSScreen.screens.first { $0.displayID == id }?.localizedName ?? "Display"
    }

    private var isEnded: Bool {
        cond.lock()
        defer { cond.unlock() }
        return ended
    }

    /// Which of the offered links a connected socket arrived on.
    private func link(ofLocalAddressOf fd: Int32) -> String {
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) == 0 }
        }
        guard ok else { return "other" }
        let address = ipv4String(addr.sin_addr)
        return endpoints.first { $0.address == address }?.link ?? "other"
    }

    /// Newest wins: a capture that arrives before the previous one went out takes
    /// its place and inherits its changed regions, so no change is ever lost.
    private func submit(_ frame: RemoteScreenCapture.Frame) {
        cond.lock()
        defer { cond.unlock() }
        guard !ended else { return }
        stats.captured += 1
        let input = lastInput.hostNs <= frame.captureHostNs ? lastInput : (0, 0)
        let next = PendingFrame(frame, input: input)
        if let old = pending {
            stats.merged += 1
            if let oldRects = old.dirtyRects, let newRects = next.dirtyRects {
                // Collapsed to their bounding box once there are too many to send,
                // so a link that stays busy does not grow the list without end.
                let merged = oldRects + newRects
                next.dirtyRects = merged.count > RemoteScreen.maxRects ? [merged.reduce(CGRect.null) { $0.union($1) }] : merged
            } else {
                next.dirtyRects = nil
            }
        }
        pending = next
        cond.signal()
    }

    /// Whole-pixel rects inside the frame, or nil when a whole frame is the better
    /// send. Too many rects — frames merged while a slow link was busy pile them
    /// up — collapse into their bounding box rather than into a whole frame,
    /// which would only make that link slower still.
    private static func patchRects(_ rects: [CGRect]?, width: Int, height: Int) -> [ScreenRect]? {
        guard let rects, !rects.isEmpty else { return nil }
        var out: [ScreenRect] = []
        var bounds = CGRect.null
        var area = 0
        for r in rects {
            let x0 = max(0, Int(r.minX.rounded(.down))), y0 = max(0, Int(r.minY.rounded(.down)))
            let x1 = min(width, Int(r.maxX.rounded(.up))), y1 = min(height, Int(r.maxY.rounded(.up)))
            guard x1 > x0, y1 > y0 else { continue }
            out.append(ScreenRect(x: UInt32(x0), y: UInt32(y0), width: UInt32(x1 - x0), height: UInt32(y1 - y0)))
            bounds = bounds.union(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            area += (x1 - x0) * (y1 - y0)
        }
        guard !out.isEmpty else { return nil }
        if out.count > RemoteScreen.maxRects {
            out = [ScreenRect(x: UInt32(bounds.minX), y: UInt32(bounds.minY), width: UInt32(bounds.width), height: UInt32(bounds.height))]
            area = out[0].area
        }
        guard area * 10 <= width * height * 6 else { return nil }
        return out
    }

    private func sendLoop() {
        cond.lock()
        let fd = videoFD
        cond.unlock()
        guard let keys else { return }
        let sender = RecordSender(fd: fd, key: keys.videoH2V)
        var plaintext = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 64)
        var capacity = 1
        var frameIndex: UInt64 = 0
        var lastSize = (width: 0, height: 0)
        var lastSendNs: UInt64 = 0
        defer {
            plaintext.deallocate()
            close(fd)
        }

        while true {
            cond.lock()
            while !ended, pending == nil { cond.wait() }
            if ended {
                cond.unlock()
                return
            }
            if minFrameIntervalNs > 0, monotonicNs() < lastSendNs + minFrameIntervalNs {
                let wait = Double(lastSendNs + minFrameIntervalNs - monotonicNs()) / 1e9
                _ = cond.wait(until: Date(timeIntervalSinceNow: wait))
                cond.unlock()
                continue
            }
            let frame = pending!
            pending = nil
            var whole = needWhole
            needWhole = false
            cond.unlock()

            let pb = frame.buffer
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
            let base = CVPixelBufferGetBaseAddress(pb)!
            if (width, height) != lastSize {
                whole = true
                lastSize = (width, height)
            }
            let full = ScreenRect(x: 0, y: 0, width: UInt32(width), height: UInt32(height))
            let rects = whole ? [full] : (Self.patchRects(frame.dirtyRects, width: width, height: height) ?? [full])
            let isWhole = rects == [full]

            frameIndex += 1
            let sendStart = monotonicNs()
            var header = WireWriter(capacity: FrameHeader.size + rects.count * 16)
            FrameHeader(whole: isWhole, frameIndex: frameIndex, width: UInt32(width), height: UInt32(height),
                        rectCount: UInt32(rects.count), captureHostNs: frame.captureHostNs, sendHostNs: sendStart,
                        inputSeq: frame.inputSeq, inputHostNs: frame.inputHostNs).encode(into: &header)
            for r in rects {
                header.u32(r.x)
                header.u32(r.y)
                header.u32(r.width)
                header.u32(r.height)
            }
            let pixelBytes = rects.reduce(0) { $0 + $1.area * 4 }
            let pixels: UnsafeRawBufferPointer
            if isWhole, bytesPerRow == width * 4 {
                // Unpadded whole frame: sealed straight from the capture buffer.
                pixels = UnsafeRawBufferPointer(start: base, count: pixelBytes)
            } else {
                if capacity < pixelBytes {
                    plaintext.deallocate()
                    plaintext = UnsafeMutableRawPointer.allocate(byteCount: pixelBytes, alignment: 64)
                    capacity = pixelBytes
                }
                var offset = 0
                for r in rects {
                    let rowBytes = Int(r.width) * 4
                    for y in Int(r.y)..<Int(r.y + r.height) {
                        plaintext.advanced(by: offset).copyMemory(from: base + y * bytesPerRow + Int(r.x) * 4, byteCount: rowBytes)
                        offset += rowBytes
                    }
                }
                pixels = UnsafeRawBufferPointer(start: plaintext, count: pixelBytes)
            }
            let size = header.bytes.count + pixelBytes

            do {
                try header.bytes.withUnsafeBytes { try sender.send([$0, pixels]) }
            } catch {
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                hostLog.error("video send failed: \(String(describing: error), privacy: .public)")
                end(.error)
                return
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            lastSendNs = sendStart
            cond.lock()
            stats.sent += 1
            stats.bytes += size
            stats.sendNs += monotonicNs() - sendStart
            if isWhole { stats.whole += 1 }
            cond.unlock()
        }
    }

    private func inputLoop() {
        cond.lock()
        let fd = inputFD
        let receiver = inputReceiver
        cond.unlock()
        guard let keys, let receiver else { return }
        let sender = RecordSender(fd: fd, key: keys.inputH2V)
        defer { close(fd) }
        do {
            while true {
                let typeByte = try receiver.read(1)[0]
                guard let type = RemoteScreen.MessageType(rawValue: typeByte), let size = type.fixedSize else {
                    throw RemoteScreenError.protocolViolation("unexpected message 0x\(String(typeByte, radix: 16)) on input channel")
                }
                let bytes = [typeByte] + (try receiver.read(size - 1))
                let now = monotonicNs()
                cond.lock()
                lastActivityNs = now
                cond.unlock()
                switch type {
                case .event:
                    guard let event = InputEventMessage(bytes) else { throw RemoteScreenError.protocolViolation("bad EVENT") }
                    inputSink?.inject(event)
                    cond.lock()
                    lastInput = (event.seq, monotonicNs())
                    cond.unlock()
                case .releaseAll:
                    inputSink?.releaseAll()
                case .requestFull:
                    cond.lock()
                    needWhole = true
                    cond.unlock()
                case .ping:
                    var r = WireReader(bytes)
                    r.skip(8)
                    var pong = WireWriter(capacity: 24)
                    pong.u8(RemoteScreen.MessageType.pong.rawValue)
                    pong.zeros(7)
                    pong.u64(r.u64())
                    pong.u64(monotonicNs())
                    try sender.send(pong.bytes)
                default:
                    throw RemoteScreenError.protocolViolation("message 0x\(String(typeByte, radix: 16)) not allowed from the viewer")
                }
            }
        } catch {
            cond.lock()
            let quiet = ended
            cond.unlock()
            if !quiet {
                hostLog.info("input channel ended: \(String(describing: error), privacy: .public)")
                // A viewer closing its window just hangs up; anything else is a fault.
                if case RemoteScreenError.closed = error { end(.other) } else { end(.error) }
            }
        }
    }

    /// Ends a session whose viewer went silent, and logs throughput every few seconds.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        var ticks = 0
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            ticks += 1
            self.cond.lock()
            let silentNs = monotonicNs() - self.lastActivityNs
            let s = self.stats
            if ticks % 10 == 0 { self.stats = Stats() }
            self.cond.unlock()
            if ticks % 10 == 0 {
                hostLog.info("5 s: captured \(s.captured, privacy: .public), sent \(s.sent, privacy: .public) (\(s.whole, privacy: .public) whole, \(s.merged, privacy: .public) merged), \(Double(s.bytes) * 8 / 5e6, format: .fixed(precision: 1), privacy: .public) Mbit/s, send \(s.sent > 0 ? Double(s.sendNs) / Double(s.sent) / 1e6 : 0, format: .fixed(precision: 2), privacy: .public) ms avg")
            }
            if Double(silentNs) / 1e9 > RemoteScreen.keepaliveTimeout {
                hostLog.error("viewer silent for \(Double(silentNs) / 1e9, format: .fixed(precision: 1), privacy: .public) s")
                self.end(.error)
            }
        }
        timer.resume()
        watchdog = timer
    }

    // MARK: - Ending

    /// Ends the session: stops capture, releases held input, shuts both
    /// connections so their threads exit, and forgets the keys.
    func end(_ reason: EndReason) {
        cond.lock()
        guard !ended else {
            cond.unlock()
            return
        }
        ended = true
        let wasStarted = started
        for fd in [videoFD, inputFD] where fd >= 0 {
            if wasStarted {
                shutdown(fd, SHUT_RDWR)  // its streaming thread closes it on the way out
            } else {
                close(fd)  // bound, but no thread was ever started for it
            }
        }
        pending = nil
        cond.broadcast()
        cond.unlock()

        watchdog?.cancel()
        watchdog = nil
        if wasStarted {
            CGDisplayRemoveReconfigurationCallback(Self.displaysReconfigured, Unmanaged.passUnretained(self).toOpaque())
        }
        controlQueue.async {
            self.restartWork?.cancel()
            self.watchingDisplays = false
            self.capturing = false
        }
        capture.onFrame = nil
        capture.onStop = nil
        capture.stop()
        if wasStarted { inputSink?.releaseAll() }
        keys = nil
        hostLog.info("session ended: \(reason.rawValue, privacy: .public)")
        onEnded?(reason)
    }
}

/// The host's IPv4 addresses, best link first, as `screen.offer` lists them.
enum RemoteScreenEndpoints {

    static func current() -> [ScreenOfferPayload.Endpoint] {
        // Link kind by BSD name. "Thunderbolt" is a brand, so the localized names
        // keep it: "Thunderbolt Bridge" (bridge0) and "Thunderbolt 1…" (en1…).
        var links: [String: String] = [:]
        for case let interface as SCNetworkInterface in (SCNetworkInterfaceCopyAll() as NSArray) {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface).map({ $0 as String }) else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(interface).map { $0 as String } ?? ""
            let name = SCNetworkInterfaceGetLocalizedDisplayName(interface).map { $0 as String } ?? ""
            if name.contains("Thunderbolt") {
                links[bsd] = "thunderbolt"
            } else if type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                links[bsd] = "wifi"
            } else if type == (kSCNetworkInterfaceTypeEthernet as String) {
                links[bsd] = "ethernet"
            } else {
                links[bsd] = "other"
            }
        }

        var endpoints: [ScreenOfferPayload.Endpoint] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard let sa = entry.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let link = links[String(cString: entry.ifa_name)]
            else { continue }
            let address = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4String($0.pointee.sin_addr) }
            endpoints.append(.init(address: address, link: link))
        }
        let order = RemoteScreen.linkPreference
        return endpoints.sorted { order.firstIndex(of: $0.link)! < order.firstIndex(of: $1.link)! }
    }
}
