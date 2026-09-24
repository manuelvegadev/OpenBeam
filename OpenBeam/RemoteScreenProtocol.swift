//
//  RemoteScreenProtocol.swift
//  OpenBeam
//
//  Wire format of the Remote Screen Protocol (SCREEN-PROTOCOL.md): the control
//  payloads carried inside ClipSync, and the binary messages and encrypted
//  records of the two data connections.
//

import CryptoKit
import Darwin
import Foundation

enum RemoteScreen {
    static let preambleMagic: [UInt8] = [0x4F, 0x42, 0x53, 0x43]  // "OBSC"
    static let version: UInt8 = 1
    static let preambleSize = 8
    static let maxRecordPlaintext = 1 << 20
    static let tagSize = 16
    static let maxRects = 256
    static let maxDimension = 16384
    static let bindTimeout: TimeInterval = 10
    static let keepaliveTimeout: TimeInterval = 3
    static let pixelFormatBGRA: UInt32 = 0x4247_5241  // "BGRA"
    /// Which offered endpoint a viewer tries first, per `screen.offer`.
    static let linkPreference = ["thunderbolt", "ethernet", "other", "wifi"]

    enum Channel: UInt8 {
        case video = 0x01
        case input = 0x02
    }

    enum MessageType: UInt8 {
        case frame = 0x01
        case event = 0x10
        case releaseAll = 0x11
        case requestFull = 0x12
        case ping = 0x20
        case pong = 0x21
        case bind = 0x30

        /// Every message but FRAME has a fixed size, type byte included.
        var fixedSize: Int? {
            switch self {
            case .frame: return nil
            case .event: return InputEventMessage.size
            case .releaseAll, .requestFull: return 8
            case .ping: return 16
            case .pong: return 24
            case .bind: return 20
            }
        }
    }
}

enum RemoteScreenError: Error, CustomStringConvertible {
    case io(String, Int32)
    case closed
    case crypto
    case protocolViolation(String)

    var description: String {
        switch self {
        case .io(let what, let code): return "\(what): \(String(cString: strerror(code)))"
        case .closed: return "connection closed"
        case .crypto: return "record failed to authenticate"
        case .protocolViolation(let what): return "protocol violation: \(what)"
        }
    }
}

// MARK: - Control payloads (inside ClipSync encrypted frames)

struct ScreenRequestPayload: Codable {
    var kind = "screen.request"
    var requestID: String
    var maxWidth: Int
    var maxHeight: Int
    var maxFPS: Int?
    /// The host display to show first, if it still has it; otherwise its main one.
    var displayID: UInt32?
    var originID: String
}

struct ScreenOfferPayload: Codable {
    struct Endpoint: Codable, Equatable {
        var address: String
        var link: String  // "thunderbolt" | "ethernet" | "wifi" | "other"
    }

    struct Display: Codable, Equatable {
        var name: String
        var width: Int
        var height: Int
        var refreshHz: Double
    }

    var kind = "screen.offer"
    var requestID: String
    var sessionID: Data
    var key: Data
    var port: Int
    var endpoints: [Endpoint]
    var display: Display
    var originID: String
}

/// One of the host's displays, laid out as the host arranges them.
struct ScreenDisplayInfo: Codable, Equatable {
    var id: UInt32
    var name: String
    /// The display's own pixels in its current mode.
    var width: Int
    var height: Int
    /// Where it sits in the host's desktop, in points, origin top left of the main display.
    var x: Double
    var y: Double
    var pointWidth: Double
    var pointHeight: Double
    var refreshHz: Double
    var main: Bool
}

/// Host → viewer: the displays the host can share, and which one it is sharing.
struct ScreenDisplaysPayload: Codable {
    var kind = "screen.displays"
    var sessionID: Data
    var displays: [ScreenDisplayInfo]
    var current: UInt32
    var originID: String
}

/// Viewer → host: share this display instead.
struct ScreenSelectPayload: Codable {
    var kind = "screen.select"
    var sessionID: Data
    var displayID: UInt32
    var originID: String
}

struct ScreenDeclinePayload: Codable {
    var kind = "screen.decline"
    var requestID: String
    var reason: String  // "not_allowed" | "busy" | "needs_screen_recording" | "needs_accessibility" | "other"
    var originID: String
}

struct ScreenStopPayload: Codable {
    var kind = "screen.stop"
    var sessionID: Data
    var reason: String  // "user" | "revoked" | "display_lost" | "error" | "other"
    var originID: String
}

// MARK: - Big-endian encoding

struct WireWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 64) { bytes.reserveCapacity(capacity) }

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) } }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func zeros(_ n: Int) { bytes.append(contentsOf: repeatElement(0, count: n)) }
    mutating func raw(_ d: Data) { bytes.append(contentsOf: d) }
}

struct WireReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func u8() -> UInt8 {
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() -> UInt16 { UInt16(u8()) << 8 | UInt16(u8()) }
    mutating func u32() -> UInt32 { UInt32(u16()) << 16 | UInt32(u16()) }
    mutating func u64() -> UInt64 { UInt64(u32()) << 32 | UInt64(u32()) }
    mutating func f64() -> Double { Double(bitPattern: u64()) }
    mutating func skip(_ n: Int) { offset += n }

    mutating func raw(_ n: Int) -> Data {
        defer { offset += n }
        return Data(bytes[offset..<offset + n])
    }
}

// MARK: - Data-channel messages

struct ScreenRect: Equatable {
    var x: UInt32, y: UInt32, width: UInt32, height: UInt32

    var area: Int { Int(width) * Int(height) }
}

struct FrameHeader {
    static let size = 64

    var whole: Bool
    var frameIndex: UInt64
    var width: UInt32
    var height: UInt32
    var rectCount: UInt32
    var captureHostNs: UInt64
    var sendHostNs: UInt64
    var inputSeq: UInt64
    var inputHostNs: UInt64

    func encode(into w: inout WireWriter) {
        w.u8(RemoteScreen.MessageType.frame.rawValue)
        w.u8(whole ? 0x01 : 0x00)
        w.zeros(2)
        w.u32(RemoteScreen.pixelFormatBGRA)
        w.u64(frameIndex)
        w.u32(width)
        w.u32(height)
        w.u32(rectCount)
        w.zeros(4)
        w.u64(captureHostNs)
        w.u64(sendHostNs)
        w.u64(inputSeq)
        w.u64(inputHostNs)
    }
}

struct BindMessage {
    var channel: RemoteScreen.Channel
    var sessionID: Data

    init?(_ bytes: [UInt8]) {
        guard bytes.count == 20 else { return nil }
        var r = WireReader(bytes)
        guard r.u8() == RemoteScreen.MessageType.bind.rawValue,
              let channel = RemoteScreen.Channel(rawValue: r.u8())
        else { return nil }
        r.skip(2)
        self.channel = channel
        sessionID = r.raw(16)
    }
}

struct InputEventMessage {
    static let size = 48

    enum Kind: UInt8 {
        case move = 1, buttonDown, buttonUp, scroll, keyDown, keyUp, modifiersChanged, mediaKey
    }

    var kind: Kind
    var button: UInt8
    var clicks: UInt8
    var keyCode: UInt16
    var scrollPhase: UInt8
    var momentumPhase: UInt8
    var flags: UInt64
    var x: Double
    var y: Double
    var seq: UInt64
    var sentViewerNs: UInt64

    init(kind: Kind, button: UInt8 = 0, clicks: UInt8 = 0, keyCode: UInt16 = 0, scrollPhase: UInt8 = 0,
         momentumPhase: UInt8 = 0, flags: UInt64 = 0, x: Double = 0, y: Double = 0, seq: UInt64 = 0, sentViewerNs: UInt64 = 0) {
        self.kind = kind
        self.button = button
        self.clicks = clicks
        self.keyCode = keyCode
        self.scrollPhase = scrollPhase
        self.momentumPhase = momentumPhase
        self.flags = flags
        self.x = x
        self.y = y
        self.seq = seq
        self.sentViewerNs = sentViewerNs
    }

    var encoded: [UInt8] {
        var w = WireWriter(capacity: Self.size)
        w.u8(RemoteScreen.MessageType.event.rawValue)
        w.u8(kind.rawValue)
        w.u8(button)
        w.u8(clicks)
        w.u16(keyCode)
        w.u8(scrollPhase)
        w.u8(momentumPhase)
        w.u64(flags)
        w.f64(x)
        w.f64(y)
        w.u64(seq)
        w.u64(sentViewerNs)
        return w.bytes
    }

    init?(_ bytes: [UInt8]) {
        guard bytes.count == Self.size else { return nil }
        var r = WireReader(bytes)
        guard r.u8() == RemoteScreen.MessageType.event.rawValue,
              let kind = Kind(rawValue: r.u8())
        else { return nil }
        self.kind = kind
        button = r.u8()
        clicks = r.u8()
        keyCode = r.u16()
        scrollPhase = r.u8()
        momentumPhase = r.u8()
        flags = r.u64()
        x = r.f64()
        y = r.f64()
        seq = r.u64()
        sentViewerNs = r.u64()
    }
}

// MARK: - Keys and records

/// The four one-way keys of a session, derived from the offer's key and sessionID.
struct ScreenSessionKeys {
    let videoV2H: SymmetricKey
    let videoH2V: SymmetricKey
    let inputV2H: SymmetricKey
    let inputH2V: SymmetricKey

    init(key: SymmetricKey, sessionID: Data) {
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: sessionID, info: Data(label.utf8), outputByteCount: 32)
        }
        videoV2H = derive("obscreen-v1 video v2h")
        videoH2V = derive("obscreen-v1 video h2v")
        inputV2H = derive("obscreen-v1 input v2h")
        inputH2V = derive("obscreen-v1 input h2v")
    }

    func viewerToHost(_ channel: RemoteScreen.Channel) -> SymmetricKey { channel == .video ? videoV2H : inputV2H }
}

private func recordNonce(_ counter: UInt64) -> AES.GCM.Nonce {
    var bytes = [UInt8](repeating: 0, count: 12)
    withUnsafeBytes(of: counter.bigEndian) { bytes.replaceSubrange(4..<12, with: $0) }
    return try! AES.GCM.Nonce(data: bytes)
}

/// Writes a plaintext stream as AES-256-GCM records. Not thread-safe: one writer per direction.
final class RecordSender {
    private let fd: Int32
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(fd: Int32, key: SymmetricKey) {
        self.fd = fd
        self.key = key
    }

    /// Seals the segments as consecutive records, in order, and writes them. A
    /// record never spans two segments, so a segment can point straight into a
    /// capture buffer. Several records are sealed on all cores at once (their
    /// nonces are known up front), and each is written as soon as it and every
    /// record before it are ready, so writing overlaps sealing.
    ///
    /// Returns only after every seal has finished: the segments' memory must stay
    /// valid for the whole call and no longer.
    func send(_ segments: [UnsafeRawBufferPointer]) throws {
        let chunk = RemoteScreen.maxRecordPlaintext
        var slices: [UnsafeRawBufferPointer] = []
        for segment in segments where segment.count > 0 {
            var start = 0
            while start < segment.count {
                slices.append(UnsafeRawBufferPointer(rebasing: segment[start..<min(segment.count, start + chunk)]))
                start += chunk
            }
        }
        guard !slices.isEmpty else { return }
        let first = counter
        counter += UInt64(slices.count)
        let key = self.key

        if slices.count == 1 {
            guard let box = try? AES.GCM.seal(slices[0], using: key, nonce: recordNonce(first)) else {
                throw RemoteScreenError.crypto
            }
            try write(box)
            return
        }

        let count = slices.count
        let boxes = UnsafeMutableBufferPointer<AES.GCM.SealedBox?>.allocate(capacity: count)
        boxes.initialize(repeating: nil)
        let sealed = (0..<count).map { _ in DispatchSemaphore(value: 0) }
        DispatchQueue.global(qos: .userInteractive).async {
            DispatchQueue.concurrentPerform(iterations: count) { i in
                boxes[i] = try? AES.GCM.seal(slices[i], using: key, nonce: recordNonce(first + UInt64(i)))
                sealed[i].signal()
            }
        }
        var failure: Error?
        for i in 0..<count {
            sealed[i].wait()
            guard failure == nil else { continue }  // keep waiting: the seals still read the segments
            do {
                guard let box = boxes[i] else { throw RemoteScreenError.crypto }
                try write(box)
            } catch {
                failure = error
            }
        }
        boxes.deinitialize()
        boxes.deallocate()
        if let failure { throw failure }
    }

    private func write(_ box: AES.GCM.SealedBox) throws {
        var length = UInt32(box.ciphertext.count + RemoteScreen.tagSize).bigEndian
        try box.ciphertext.withUnsafeBytes { ct in
            try box.tag.withUnsafeBytes { tag in
                try withUnsafeMutableBytes(of: &length) { len in
                    try writeVectors(fd, [UnsafeRawBufferPointer(len), ct, tag])
                }
            }
        }
    }

    func send(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try send([$0]) }
    }
}

/// Reads AES-256-GCM records. `read` hands out the plaintext stream as whole
/// messages, for small ones; `nextRecord` hands out each record's plaintext as
/// it opens, for a caller that parses large messages as they arrive.
final class RecordReceiver {
    private let fd: Int32
    private let key: SymmetricKey
    private var counter: UInt64 = 0
    private var pending: [UInt8] = []
    private var pendingOffset = 0
    private let sealed = UnsafeMutableRawPointer.allocate(byteCount: RemoteScreen.maxRecordPlaintext + RemoteScreen.tagSize,
                                                          alignment: 64)

    init(fd: Int32, key: SymmetricKey) {
        self.fd = fd
        self.key = key
    }

    deinit { sealed.deallocate() }

    /// The next `count` bytes of plaintext, reading and opening records as needed.
    func read(_ count: Int) throws -> [UInt8] {
        while pending.count - pendingOffset < count {
            let record = try nextRecord()
            pending.removeFirst(pendingOffset)
            pendingOffset = 0
            pending.append(contentsOf: record)
        }
        defer { pendingOffset += count }
        return Array(pending[pendingOffset..<pendingOffset + count])
    }

    /// Reads and opens one record. Not to be mixed with `read` on the same stream.
    func nextRecord() throws -> Data {
        var length: UInt32 = 0
        try withUnsafeMutableBytes(of: &length) { try readExactly(fd, $0) }
        let size = Int(UInt32(bigEndian: length))
        guard size >= RemoteScreen.tagSize, size <= RemoteScreen.maxRecordPlaintext + RemoteScreen.tagSize else {
            throw RemoteScreenError.protocolViolation("record length \(size)")
        }
        try readExactly(fd, UnsafeMutableRawBufferPointer(start: sealed, count: size))
        defer { counter += 1 }
        let ciphertext = UnsafeRawBufferPointer(start: sealed, count: size - RemoteScreen.tagSize)
        let tag = UnsafeRawBufferPointer(start: sealed + size - RemoteScreen.tagSize, count: RemoteScreen.tagSize)
        guard let box = try? AES.GCM.SealedBox(nonce: recordNonce(counter), ciphertext: ciphertext, tag: tag),
              let plaintext = try? AES.GCM.open(box, using: key)
        else { throw RemoteScreenError.crypto }
        return plaintext
    }
}

// MARK: - Sockets

func writeVectors(_ fd: Int32, _ buffers: [UnsafeRawBufferPointer]) throws {
    var vectors = buffers.map { iovec(iov_base: UnsafeMutableRawPointer(mutating: $0.baseAddress), iov_len: $0.count) }
    var remaining = buffers.reduce(0) { $0 + $1.count }
    var index = 0
    while remaining > 0 {
        let n = vectors[index...].withUnsafeMutableBufferPointer { Darwin.writev(fd, $0.baseAddress, Int32($0.count)) }
        if n < 0 {
            if errno == EINTR { continue }
            throw RemoteScreenError.io("write", errno)
        }
        remaining -= n
        var written = n
        while index < vectors.count, written >= vectors[index].iov_len {
            written -= vectors[index].iov_len
            index += 1
        }
        if written > 0 {
            vectors[index].iov_base = vectors[index].iov_base.map { $0 + written }
            vectors[index].iov_len -= written
        }
    }
}

func readExactly(_ fd: Int32, _ buffer: UnsafeMutableRawBufferPointer) throws {
    var offset = 0
    while offset < buffer.count {
        let n = Darwin.read(fd, buffer.baseAddress! + offset, buffer.count - offset)
        if n < 0 {
            if errno == EINTR { continue }
            throw RemoteScreenError.io("read", errno)
        }
        if n == 0 { throw RemoteScreenError.closed }
        offset += n
    }
}

func setSocketOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) {
    var v = value
    setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size))
}

/// Blocking reads on `fd` give up after `seconds`; 0 waits forever.
func setReceiveTimeout(_ fd: Int32, seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

/// Dotted-quad text for an IPv4 address.
func ipv4String(_ address: in_addr) -> String {
    var address = address
    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN))
    return String(cString: text)
}

/// Host monotonic clock, the base of every `…HostNs` field.
@inline(__always) func monotonicNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
