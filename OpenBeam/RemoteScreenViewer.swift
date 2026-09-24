//
//  RemoteScreenViewer.swift
//  OpenBeam
//
//  The viewer side of a remote screen session (SCREEN-PROTOCOL.md): connects
//  to the host's offer, turns the video stream into canvas updates as the
//  bytes arrive, keeps the host's clock in view, and carries input back.
//

import AppKit
import CryptoKit
import Metal
import os

private let viewerLog = Logger(subsystem: "com.openbeam.remotescreen", category: "viewer")

final class RemoteScreenViewer: @unchecked Sendable {
    /// Why a session ended, as the plugin needs to know it: whether to reconnect.
    enum End: Equatable {
        /// This side closed it on purpose.
        case closed
        /// The host sent `screen.stop` with this wire reason.
        case hostStopped(RemoteScreenHost.EndReason)
        /// The connection failed or the host went silent.
        case failed(String)
    }

    enum State: Equatable {
        case connecting
        case streaming
        case ended(End)
    }

    /// Delivered on the main queue.
    var onStateChange: ((State) -> Void)?
    let offer: ScreenOfferPayload
    let canvas: ScreenCanvas
    let stats = RemoteScreenStats()

    private let keys: ScreenSessionKeys
    private let inputQueue = DispatchQueue(label: "com.openbeam.remotescreen.input", qos: .userInteractive)
    private let lock = NSLock()
    private var videoFD: Int32 = -1
    private var inputFD: Int32 = -1
    private var inputSender: RecordSender?  // inputQueue only
    private var pingTimer: DispatchSourceTimer?
    private var ended = false
    private var lastPongNs: UInt64 = 0
    private var clockSamples: [(rtt: UInt64, offset: Int64)] = []
    private var clock: (rtt: UInt64, offset: Int64) = (0, 0)

    init?(offer: ScreenOfferPayload, device: MTLDevice) {
        guard offer.sessionID.count == 16, offer.key.count == 32, let canvas = ScreenCanvas(device: device) else { return nil }
        self.offer = offer
        self.canvas = canvas
        keys = ScreenSessionKeys(key: SymmetricKey(data: offer.key), sessionID: offer.sessionID)
    }

    /// Host clock minus viewer clock, from the fastest recent PING round trip.
    var clockOffsetNs: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return clock.offset
    }

    var roundTripNs: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return clock.rtt
    }

    func start() {
        report(.connecting)
        let thread = Thread { self.run() }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Ends the session. The host sees both connections close.
    func stop(_ end: End) {
        lock.lock()
        guard !ended else {
            lock.unlock()
            return
        }
        ended = true
        for fd in [videoFD, inputFD] where fd >= 0 { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        pingTimer?.cancel()
        viewerLog.info("session ended: \(String(describing: end), privacy: .public)")
        report(.ended(end))
    }

    private var inputSeq: UInt64 = 0  // inputQueue only

    /// Numbers, stamps and sends one input event; events go out in call order.
    func send(_ event: InputEventMessage) {
        inputQueue.async {
            guard let sender = self.inputSender else { return }
            var e = event
            self.inputSeq += 1
            e.seq = self.inputSeq
            e.sentViewerNs = monotonicNs()
            self.stats.inputSent(seq: e.seq, at: e.sentViewerNs)
            self.write(e.encoded, with: sender)
        }
    }

    /// Tells the host to let go of every key and button this viewer holds down.
    func releaseAll() {
        send([RemoteScreen.MessageType.releaseAll.rawValue] + [UInt8](repeating: 0, count: 7))
    }

    /// Sends one input-channel message; messages go out in call order.
    private func send(_ message: [UInt8]) {
        inputQueue.async {
            guard let sender = self.inputSender else { return }
            self.write(message, with: sender)
        }
    }

    /// inputQueue only.
    private func write(_ message: [UInt8], with sender: RecordSender) {
        do {
            try sender.send(message)
        } catch {
            stop(.failed("input channel: \(error)"))
        }
    }

    private func report(_ state: State) {
        DispatchQueue.main.async { self.onStateChange?(state) }
    }

    // MARK: - Connecting

    private func run() {
        let order = RemoteScreen.linkPreference
        let endpoints = offer.endpoints.sorted {
            (order.firstIndex(of: $0.link) ?? order.count) < (order.firstIndex(of: $1.link) ?? order.count)
        }
        var chosen: (endpoint: ScreenOfferPayload.Endpoint, video: Int32)?
        for endpoint in endpoints {
            if let fd = Self.connect(endpoint.address, offer.port) {
                chosen = (endpoint, fd)
                break
            }
        }
        guard let (endpoint, video) = chosen, let input = Self.connect(endpoint.address, offer.port) else {
            if let chosen { close(chosen.video) }
            stop(.failed("no endpoint reachable"))
            return
        }
        viewerLog.info("connected over \(endpoint.link, privacy: .public) \(endpoint.address, privacy: .public):\(self.offer.port, privacy: .public)")
        lock.lock()
        let already = ended
        videoFD = video
        inputFD = input
        lock.unlock()
        if already {
            close(video)
            close(input)
            return
        }

        do {
            try bind(video, channel: .video)
            let sender = try bind(input, channel: .input)
            inputQueue.sync { inputSender = sender }
        } catch {
            stop(.failed("bind: \(error)"))
            close(video)  // neither loop started, so nothing else will
            close(input)
            return
        }
        report(.streaming)
        startClockProbe(input)
        receiveVideo(video)
    }

    /// Opens a TCP connection within 1 s, or gives up.
    private static func connect(_ address: String, _ port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else {
            close(fd)
            return nil
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard rc == 0 || errno == EINPROGRESS, poll(&pfd, 1, 1000) == 1,
              getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0
        else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, flags)
        setSocketOption(fd, IPPROTO_TCP, TCP_NODELAY, 1)
        setSocketOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
        setSocketOption(fd, SOL_SOCKET, SO_RCVBUF, 16 << 20)
        return fd
    }

    /// Sends the preamble and BIND; returns the sender for the rest of that direction.
    @discardableResult
    private func bind(_ fd: Int32, channel: RemoteScreen.Channel) throws -> RecordSender {
        let preamble = RemoteScreen.preambleMagic + [RemoteScreen.version, channel.rawValue, 0, 0]
        try preamble.withUnsafeBytes { try writeVectors(fd, [$0]) }
        let sender = RecordSender(fd: fd, key: keys.viewerToHost(channel))
        try sender.send([RemoteScreen.MessageType.bind.rawValue, channel.rawValue, 0, 0] + [UInt8](offer.sessionID))
        return sender
    }

    // MARK: - Clock probe

    /// PING every 100 ms (also the session's keepalive), and read the PONGs. A
    /// host that stops answering — asleep, or the cable pulled, where TCP alone
    /// could wait for minutes — ends the session after the spec's 3 s.
    private func startClockProbe(_ fd: Int32) {
        lock.lock()
        lastPongNs = monotonicNs()
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: inputQueue)
        timer.schedule(deadline: .now(), repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let silentNs = monotonicNs() - self.lastPongNs
            self.lock.unlock()
            if Double(silentNs) / 1e9 > RemoteScreen.keepaliveTimeout {
                self.stop(.failed("host stopped answering"))
                return
            }
            var ping = WireWriter(capacity: 16)
            ping.u8(RemoteScreen.MessageType.ping.rawValue)
            ping.zeros(7)
            ping.u64(monotonicNs())
            self.send(ping.bytes)
        }
        timer.resume()
        pingTimer = timer

        let reader = Thread {
            let receiver = RecordReceiver(fd: fd, key: self.keys.inputH2V)
            defer { close(fd) }
            do {
                while true {
                    let bytes = try receiver.read(24)
                    let received = monotonicNs()
                    var r = WireReader(bytes)
                    guard r.u8() == RemoteScreen.MessageType.pong.rawValue else {
                        throw RemoteScreenError.protocolViolation("expected PONG")
                    }
                    r.skip(7)
                    let sent = r.u64(), host = r.u64()
                    let rtt = received - sent
                    self.lock.lock()
                    self.lastPongNs = received
                    self.clockSamples.append((rtt, Int64(host) - Int64(sent + rtt / 2)))
                    if self.clockSamples.count > 50 { self.clockSamples.removeFirst() }
                    self.clock = self.clockSamples.min { $0.rtt < $1.rtt }!
                    self.lock.unlock()
                }
            } catch {
                self.stop(.failed("input channel: \(error)"))
            }
        }
        reader.qualityOfService = .userInitiated
        reader.start()
    }

    // MARK: - Video

    /// Parses FRAMEs straight out of each record as it opens, copying pixels
    /// into a staging buffer, so decoding keeps pace with the socket.
    private func receiveVideo(_ fd: Int32) {
        let receiver = RecordReceiver(fd: fd, key: keys.videoH2V)
        var parser = FrameParser(canvas: canvas, stats: stats)
        defer { close(fd) }
        do {
            while true {
                let record = try receiver.nextRecord()
                try record.withUnsafeBytes { try parser.consume($0) }
            }
        } catch {
            stop(.failed("video channel: \(error)"))
        }
    }
}

/// Reassembles FRAMEs from a plaintext stream whose record boundaries fall anywhere.
private struct FrameParser {
    private enum Phase {
        case header
        case rects(header: [UInt8], count: Int)
        case pixels(info: ScreenFrameInfo, rects: [ScreenRect], buffer: MTLBuffer, offset: Int, total: Int)
    }

    private let canvas: ScreenCanvas
    private let stats: RemoteScreenStats
    private var phase = Phase.header
    private var pending: [UInt8] = []  // header or rect bytes gathered so far
    private var size: (width: Int, height: Int)?
    private var lastIndex: UInt64 = 0

    init(canvas: ScreenCanvas, stats: RemoteScreenStats) {
        self.canvas = canvas
        self.stats = stats
    }

    mutating func consume(_ bytes: UnsafeRawBufferPointer) throws {
        var at = 0
        while at < bytes.count {
            switch phase {
            case .header:
                at += gather(bytes, from: at, upTo: FrameHeader.size)
                if pending.count == FrameHeader.size {
                    let header = pending
                    pending.removeAll(keepingCapacity: true)
                    guard header[0] == RemoteScreen.MessageType.frame.rawValue else {
                        throw RemoteScreenError.protocolViolation("expected FRAME, got 0x\(String(header[0], radix: 16))")
                    }
                    var r = WireReader(header)
                    r.skip(24)
                    let count = Int(r.u32())
                    guard (1...RemoteScreen.maxRects).contains(count) else {
                        throw RemoteScreenError.protocolViolation("rectCount \(count)")
                    }
                    phase = .rects(header: header, count: count)
                }
            case .rects(let header, let count):
                at += gather(bytes, from: at, upTo: count * 16)
                if pending.count == count * 16 {
                    phase = try beginPixels(header: header, rectBytes: pending)
                    pending.removeAll(keepingCapacity: true)
                }
            case .pixels(let info, let rects, let buffer, let offset, let total):
                let n = min(total - offset, bytes.count - at)
                (buffer.contents() + offset).copyMemory(from: bytes.baseAddress! + at, byteCount: n)
                at += n
                if offset + n == total {
                    var done = info
                    done.receivedNs = monotonicNs()
                    canvas.apply(rects, from: buffer, info: done)
                    stats.received(bytes: FrameHeader.size + rects.count * 16 + total, whole: info.whole,
                                   width: info.width, height: info.height)
                    phase = .header
                } else {
                    phase = .pixels(info: info, rects: rects, buffer: buffer, offset: offset + n, total: total)
                }
            }
        }
    }

    private mutating func gather(_ bytes: UnsafeRawBufferPointer, from at: Int, upTo target: Int) -> Int {
        let n = min(target - pending.count, bytes.count - at)
        pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[at..<at + n]))
        return n
    }

    /// Validates a FRAME's header and rects against the spec, and picks where its pixels go.
    private mutating func beginPixels(header: [UInt8], rectBytes: [UInt8]) throws -> Phase {
        var r = WireReader(header)
        r.skip(1)
        let whole = r.u8() & 0x01 != 0
        r.skip(2)
        guard r.u32() == RemoteScreen.pixelFormatBGRA else { throw RemoteScreenError.protocolViolation("pixel format") }
        let index = r.u64()
        let width = Int(r.u32()), height = Int(r.u32())
        let count = Int(r.u32())
        r.skip(4)
        let info = ScreenFrameInfo(index: index, width: width, height: height, whole: whole,
                                   captureHostNs: r.u64(), sendHostNs: r.u64(), receivedNs: 0,
                                   inputSeq: r.u64())  // inputHostNs, the last field, is not needed here
        guard index > lastIndex else { throw RemoteScreenError.protocolViolation("frameIndex \(index) after \(lastIndex)") }
        guard (1...RemoteScreen.maxDimension).contains(width), (1...RemoteScreen.maxDimension).contains(height) else {
            throw RemoteScreenError.protocolViolation("frame size \(width)×\(height)")
        }
        guard whole || size.map({ $0 == (width, height) }) == true else {
            throw RemoteScreenError.protocolViolation("partial frame without a whole one of the same size first")
        }
        lastIndex = index
        size = (width, height)

        var rects: [ScreenRect] = []
        var rr = WireReader(rectBytes)
        var total = 0
        for _ in 0..<count {
            let rect = ScreenRect(x: rr.u32(), y: rr.u32(), width: rr.u32(), height: rr.u32())
            guard rect.width > 0, rect.height > 0, Int(rect.x) + Int(rect.width) <= width, Int(rect.y) + Int(rect.height) <= height else {
                throw RemoteScreenError.protocolViolation("rect outside the frame")
            }
            rects.append(rect)
            total += rect.area * 4
        }
        guard let buffer = canvas.stagingBuffer(length: total) else {
            throw RemoteScreenError.protocolViolation("no staging memory for \(total) bytes")
        }
        return .pixels(info: info, rects: rects, buffer: buffer, offset: 0, total: total)
    }
}

/// Per-second viewer statistics: what arrived, what reached the glass, and how long each stage took.
final class RemoteScreenStats: @unchecked Sendable {
    struct Snapshot {
        var received = 0, shown = 0, whole = 0, bytes = 0
        var width = 0, height = 0
        var queue: [Double] = [], transfer: [Double] = [], display: [Double] = [], total: [Double] = []
        var held = [0, 0, 0]  // frames on screen for 1, 2, 3+ refreshes
        var inputToPhoton: [Double] = []

        var summary: String {
            /// p50/p95, from one sort.
            func p(_ values: [Double]) -> String {
                guard !values.isEmpty else { return "–/–" }
                let sorted = values.sorted()
                let at = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q + 0.5))] }
                return String(format: "%.1f/%.1f", at(0.5), at(0.95))
            }
            return String(format: "%d×%d  %d fps shown, %d received (%d whole), %.0f Mbit/s, held 1/2/3+ %d/%d/%d\n",
                          width, height, shown, received, whole, Double(bytes) * 8 / 1e6, held[0], held[1], held[2])
                + "ms p50/p95  capture→send \(p(queue))  transfer \(p(transfer))  on screen \(p(display))  total \(p(total))"
                + (inputToPhoton.isEmpty ? "" : "  input→photon \(p(inputToPhoton))")
        }
    }

    private let lock = NSLock()
    private var current = Snapshot()
    private var lastPresent: Int64 = 0
    private var inputSentNs: [UInt64: UInt64] = [:]  // seq → viewer time sent
    private var lastInputShown: UInt64 = 0

    func inputSent(seq: UInt64, at ns: UInt64) {
        lock.lock()
        inputSentNs[seq] = ns
        if inputSentNs.count > 4096 { inputSentNs = inputSentNs.filter { $0.key + 2048 > seq } }
        lock.unlock()
    }

    func received(bytes: Int, whole: Bool, width: Int, height: Int) {
        lock.lock()
        current.width = width
        current.height = height
        current.received += 1
        current.bytes += bytes
        if whole { current.whole += 1 }
        lock.unlock()
    }

    func presented(_ info: ScreenFrameInfo, at presentedTime: CFTimeInterval, clockOffsetNs offset: Int64, refreshInterval: Double) {
        guard presentedTime > 0 else { return }
        let present = Int64(presentedTime * 1e9)
        lock.lock()
        defer { lock.unlock() }
        current.shown += 1
        current.queue.append(Double(Int64(info.sendHostNs) - Int64(info.captureHostNs)) / 1e6)
        current.transfer.append(Double(Int64(info.receivedNs) - (Int64(info.sendHostNs) - offset)) / 1e6)
        current.display.append(Double(present - Int64(info.receivedNs)) / 1e6)
        current.total.append(Double(present - (Int64(info.captureHostNs) - offset)) / 1e6)
        if lastPresent > 0, refreshInterval > 0 {
            let refreshes = Int((Double(present - lastPresent) / 1e9 / refreshInterval).rounded())
            current.held[min(2, max(0, refreshes - 1))] += 1
        }
        lastPresent = present
        // The first frame shown that was composited after an event is the first
        // that can show its effect: that ends the event's round trip.
        if info.inputSeq > lastInputShown, let sent = inputSentNs[info.inputSeq] {
            lastInputShown = info.inputSeq
            current.inputToPhoton.append(Double(present - Int64(sent)) / 1e6)
        }
    }

    /// The last second's numbers, starting a new second.
    func take() -> Snapshot {
        lock.lock()
        defer {
            current = Snapshot()
            lock.unlock()
        }
        return current
    }
}

extension NSScreen {
    /// Where a remote screen shows best when nobody said where: a screen
    /// refreshing at the host's own rate, so every frame lasts exactly one
    /// refresh (a 120 Hz host on a 165 Hz screen measurably judders), otherwise
    /// the main screen.
    static func bestForRemoteScreen(refreshHz: Double) -> NSScreen? {
        screens.first { abs(Double($0.maximumFramesPerSecond) - refreshHz) < 1 } ?? main
    }
}

/// The window a remote screen is shown in. It outlives any one session: when a
/// session drops, the last picture stays up under a status line while the
/// plugin reconnects, and the next session is attached to the same window,
/// still full screen.
final class RemoteScreenWindowController: NSWindowController, NSWindowDelegate {
    /// The user closed the window.
    var onClose: (() -> Void)?
    /// The user picked another host display.
    var onSelectDisplay: ((UInt32) -> Void)?
    private(set) var viewer: RemoteScreenViewer?
    private let picker = RemoteScreenDisplayPicker()
    private var pickerHide: DispatchWorkItem?

    private let container: NSView
    private let status: NSTextField
    private var screenView: ScreenView?
    private var input: RemoteScreenInput?
    private var keyboardCapture: SystemKeyboardCapture?
    private var statsTimer: Timer?
    private var seconds = 0
    private let showsStats: Bool

    init(on screen: NSScreen, title: String, aspect: CGSize, showsStats: Bool) {
        self.showsStats = showsStats
        let frame = screen.visibleFrame.insetBy(dx: screen.visibleFrame.width * 0.1, dy: screen.visibleFrame.height * 0.1)
        container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 15, weight: .medium)
        status.textColor = .white
        status.alignment = .center
        status.drawsBackground = true
        status.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        status.isHidden = true
        status.translatesAutoresizingMaskIntoConstraints = false
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false, screen: screen)
        window.title = title
        window.contentView = container
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentAspectRatio = aspect
        window.acceptsMouseMovedEvents = true
        super.init(window: window)
        window.delegate = self

        picker.frame = container.bounds
        picker.autoresizingMask = [.width, .height]
        picker.isHidden = true
        container.addSubview(picker)
        container.addSubview(status)
        picker.onChoose = { [weak self] id in
            self?.select(id)
            self?.hidePicker()
        }
        picker.onDismiss = { [weak self] in self?.hidePicker() }
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `viewer`'s picture and routes input to it, replacing any previous
    /// session's. False if the GPU view could not be made.
    func attach(_ viewer: RemoteScreenViewer) -> Bool {
        guard let window, let view = ScreenView(frame: container.bounds, canvas: viewer.canvas) else { return false }
        detach()
        view.autoresizingMask = [.width, .height]
        view.showsStats = showsStats
        container.addSubview(view, positioned: .below, relativeTo: picker)
        screenView?.removeFromSuperview()
        screenView = view
        let input = RemoteScreenInput(viewer: viewer)
        input.onLocalCommand = { [weak self] command in self?.run(command) }
        view.input = input
        self.input = input
        self.viewer = viewer
        window.makeFirstResponder(view)

        viewer.canvas.onUpdate = { [weak view] in
            guard let view else { return }
            view.renderQueue.async { view.renderLatest() }
        }
        // Read here on the main thread: the handler below runs on Metal's.
        let refreshInterval = 1 / Double(max(window.screen?.maximumFramesPerSecond ?? 60, 1))
        view.onPresented = { [weak viewer] info, time in
            guard let viewer else { return }
            viewer.stats.presented(info, at: time, clockOffsetNs: viewer.clockOffsetNs, refreshInterval: refreshInterval)
        }
        view.onRemoteSizeChange = { [weak window] size in
            window?.contentAspectRatio = size
        }
        if RemoteScreenPreferences.capturesSystemShortcuts {
            let capture = SystemKeyboardCapture(input: input, window: window) { [weak window] in
                NSApp.isActive && window?.isKeyWindow == true
            }
            if capture.start() {
                keyboardCapture = capture
            } else {
                viewerLog.error("system shortcuts stay on this Mac: no Accessibility permission for the keyboard tap")
            }
        }
        showStatus(nil)
        return true
    }

    /// Stops sending input for the current session, whose picture stays up.
    func detach() {
        hidePicker()
        keyboardCapture?.stop()
        keyboardCapture = nil
        input?.releaseAll()
        screenView?.input = nil
        input = nil
        viewer = nil
    }

    // MARK: - Host displays

    /// The host's displays, from `screen.displays`.
    func updateDisplays(_ displays: [ScreenDisplayInfo], current: UInt32) {
        picker.update(displays: displays, current: current)
    }

    private func run(_ command: RemoteScreenInput.LocalCommand) {
        switch command {
        case .displayPicker:
            if picker.isHidden || !picker.isInteractive { showPicker(interactive: true) } else { hidePicker() }
        case .previousDisplay, .nextDisplay:
            if let next = picker.neighbor(of: picker.current, step: command == .nextDisplay ? 1 : -1) {
                select(next)
            }
            if !picker.isInteractive { showPicker(interactive: false) }  // a moment's notice of where you are
        }
    }

    private func select(_ id: UInt32) {
        guard id != picker.current else { return }
        picker.current = id  // at once; the host's confirmation follows
        picker.resetHighlight()
        onSelectDisplay?(id)
    }

    /// Interactive, it takes the keyboard (← → Return Esc) and the pointer until
    /// closed; otherwise it shows for a moment and lets everything through.
    private func showPicker(interactive: Bool) {
        pickerHide?.cancel()
        picker.isInteractive = interactive
        picker.resetHighlight()
        picker.isHidden = false
        picker.needsDisplay = true
        if interactive {
            input?.pointerSuspended = true
            input?.localKeys = { [weak self] keyCode in self?.pickerKey(keyCode) ?? false }
        } else {
            let hide = DispatchWorkItem { [weak self] in self?.hidePicker() }
            pickerHide = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: hide)
        }
    }

    private func hidePicker() {
        pickerHide?.cancel()
        picker.isHidden = true
        picker.isInteractive = false
        input?.pointerSuspended = false
        input?.localKeys = nil
    }

    private func pickerKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 123: picker.moveHighlight(by: -1)
        case 124: picker.moveHighlight(by: 1)
        case 36, 76:  // Return, Enter
            select(picker.highlighted)
            hidePicker()
        case 53: hidePicker()  // Escape
        default: return false
        }
        return true
    }

    /// A line over the picture, or nil to hide it.
    func showStatus(_ text: String?) {
        status.stringValue = text.map { "   \($0)   " } ?? ""
        status.isHidden = text == nil
    }

    // MARK: - Full screen

    /// Full screen here is the other Mac's screen edge to edge, its own menu bar
    /// along the top of the picture, in a desktop of its own as any full-screen
    /// app. This Mac's menu bar slides down over that edge on hover and would take
    /// the clicks. Hiding it through presentation options works on the main
    /// display only, so on entering full screen the window is also lifted above
    /// the menu bar's level: wherever the menu bar appears, it appears beneath.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        [.fullScreen, .hideDock, .hideMenuBar]
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        window?.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        window?.level = .normal
    }

    func windowWillClose(_ notification: Notification) {
        statsTimer?.invalidate()
        detach()
        onClose?()
    }

    /// Input stops reaching this window, so nothing may stay held on the host.
    func windowDidResignKey(_ notification: Notification) {
        input?.releaseAll()
    }

    private func tick() {
        guard let viewer, let screenView else { return }
        let snapshot = viewer.stats.take()
        let text = snapshot.summary + String(format: "  rtt %.2f ms", Double(viewer.roundTripNs) / 1e6)
        screenView.setStatsText(text)
        seconds += 1
        if seconds % 5 == 0 {
            viewerLog.info("\(text.replacingOccurrences(of: "\n", with: " | "), privacy: .public)")
        }
    }
}
