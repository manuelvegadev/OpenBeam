//
//  ClipSyncProtocol.swift
//  OpenBeam
//
//  ClipSync v1 wire-protocol model: packet types, JSON envelope, length-prefix
//  framing, protocol constants. The canonical specification lives in
//  ../../../CLIPBOARD-PROTOCOL.md — keep that file authoritative; this is the
//  Swift binding.
//

import Foundation

enum ClipSync {

    static let protocolVersion = 1
    static let serviceType = "_clipsync._tcp"

    // Limits — see "Limits Summary" in the spec.
    static let maxFrameBytes = 1 * 1024 * 1024            // 1 MiB
    static let maxTextBytes = 256 * 1024                  // 256 KB
    static let maxShareFileCount = 10
    static let maxShareTotalBytes = 100 * 1024 * 1024     // 100 MB
    static let maxChunkPlaintextBytes = 256 * 1024        // 256 KiB
    static let idleTimeoutSeconds: Double = 300
    static let pairDialogTimeoutSeconds: Double = 30
    static let maxDisplayNameLength = 64

    // Domain separators / HKDF info strings — must match spec verbatim.
    static let helloDomain = Data("clipsync-v1\0hello\0".utf8)
    static let sessionInfo = Data("clipsync-v1-session".utf8)
    static let pairVerifyInfo = Data("clipsync-v1-pair-verify".utf8)

    static let osIdentifier = "macos"
}

// MARK: - Cleartext control frames (handshake + pairing)

struct HelloFrame: Codable {
    var v: Int
    var type: String              // "hello"
    var peerID: String
    var displayName: String
    var os: String
    var sigPub: Data              // base64 in JSON via Data's default encoding
    var kxPub: Data
    var ephPub: Data
    var sig: Data
}

struct PairRequestFrame: Codable {
    var v: Int
    var type: String              // "pair_request"
    var peerID: String
    var displayName: String
    var os: String
    var sigPub: Data
    var kxPub: Data
}

struct PairAcceptFrame: Codable {
    var v: Int
    var type: String              // "pair_accept"
    var peerID: String
    var displayName: String
    var os: String
    var sigPub: Data
    var kxPub: Data
}

struct PairRejectFrame: Codable {
    var v: Int
    var type: String              // "pair_reject"
    var reason: String            // "user" | "timeout" | "mismatch" | "other"
}

// MARK: - Encrypted envelope

struct EncryptedFrame: Codable {
    var v: Int
    var type: String              // "encrypted"
    var n: UInt64
    var ct: Data
}

// MARK: - Encrypted payload kinds

struct ClipboardTextPayload: Codable {
    var kind: String              // "clipboard.text" or "clipboard.text.snapshot"
    var body: String
    var sentAt: Int64
    var originID: String
    var contentHash: String       // hex SHA-256 of body utf-8 bytes
}

struct ShareFileMeta: Codable {
    var name: String
    var size: Int64
    var sha256: String            // hex
}

struct ShareBeginPayload: Codable {
    var kind: String              // "share.begin"
    var transferID: String
    var files: [ShareFileMeta]
    var totalBytes: Int64
    var sentAt: Int64
    var originID: String
}

struct ShareChunkPayload: Codable {
    var kind: String              // "share.chunk"
    var transferID: String
    var fileIndex: Int
    var chunkIndex: Int
    var totalChunks: Int
    var data: Data
}

struct ShareEndPayload: Codable {
    var kind: String              // "share.end"
    var transferID: String
}

struct ShareCancelPayload: Codable {
    var kind: String              // "share.cancel"
    var transferID: String
    var reason: String
}

struct PingPayload: Codable {
    var kind: String              // "ping" or "pong"
    var nonce: String
}

// MARK: - Decoded type discriminator

enum ControlFrameType: String {
    case hello = "hello"
    case pairRequest = "pair_request"
    case pairAccept = "pair_accept"
    case pairReject = "pair_reject"
    case encrypted = "encrypted"
}

// MARK: - JSON helpers

enum ClipSyncJSON {

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dataEncodingStrategy = .base64
        e.outputFormatting = []
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dataDecodingStrategy = .base64
        return d
    }()

    /// Decodes the top-level `type` field without parsing the whole frame.
    static func peekType(_ data: Data) -> ControlFrameType? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj["type"] as? String else { return nil }
        return ControlFrameType(rawValue: s)
    }

    /// Decodes the encrypted plaintext's `kind` field without parsing the whole struct.
    static func peekKind(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["kind"] as? String
    }
}

// MARK: - Length-prefix framing (UInt32 BE length || JSON bytes)

enum ClipSyncFraming {

    /// Wraps `body` with a 4-byte big-endian length prefix.
    static func wrap(_ body: Data) -> Data {
        precondition(body.count <= ClipSync.maxFrameBytes, "frame too large")
        var len = UInt32(body.count).bigEndian
        var out = Data(capacity: 4 + body.count)
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    /// Stateful decoder. Append received bytes via `append(_:)` and call
    /// `nextFrame()` repeatedly until it returns nil.
    final class Decoder {
        private var buffer = Data()

        func append(_ data: Data) {
            buffer.append(data)
        }

        /// Returns the next complete frame body (without length prefix), or nil
        /// if more bytes are needed. Throws if a frame exceeds the cap.
        func nextFrame() throws -> Data? {
            guard buffer.count >= 4 else { return nil }
            let lengthBE: UInt32 = buffer.prefix(4).withUnsafeBytes { raw in
                raw.load(as: UInt32.self)
            }
            let length = Int(UInt32(bigEndian: lengthBE))
            if length > ClipSync.maxFrameBytes {
                throw ClipSyncError.frameTooLarge(length)
            }
            guard buffer.count >= 4 + length else { return nil }
            let body = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))
            return body
        }
    }
}

// MARK: - Errors

enum ClipSyncError: Error, CustomStringConvertible {
    case frameTooLarge(Int)
    case malformedFrame(String)
    case unknownFrameType(String)
    case versionMismatch(Int)
    case signatureInvalid
    case identityMismatch
    case nonceReplay(UInt64)
    case decryptFailed
    case limitExceeded(String)
    case keychain(OSStatus)
    case invalidPeer

    var description: String {
        switch self {
        case .frameTooLarge(let n): return "frame too large: \(n) bytes"
        case .malformedFrame(let s): return "malformed frame: \(s)"
        case .unknownFrameType(let s): return "unknown frame type: \(s)"
        case .versionMismatch(let v): return "unsupported protocol version: \(v)"
        case .signatureInvalid: return "hello signature verification failed"
        case .identityMismatch: return "peer identity does not match pinned key"
        case .nonceReplay(let n): return "nonce replay or out-of-order: \(n)"
        case .decryptFailed: return "ChaCha20-Poly1305 decrypt failed"
        case .limitExceeded(let what): return "limit exceeded: \(what)"
        case .keychain(let s): return "keychain error: OSStatus \(s)"
        case .invalidPeer: return "invalid or unknown peer"
        }
    }
}
