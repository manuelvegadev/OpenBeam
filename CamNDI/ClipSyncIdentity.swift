//
//  ClipSyncIdentity.swift
//  CamNDI
//
//  Long-term identity (Ed25519 signing key + X25519 key-exchange key) and
//  paired-peer persistence for ClipSync v1. Private keys live in the Keychain
//  as a single 64-byte blob; the device UUID and paired-peers list live in
//  UserDefaults.
//

import Foundation
import CryptoKit
import Security
import os

// MARK: - Public records

struct PairedPeer: Codable, Hashable {
    let peerID: String                  // remote's UUID
    let displayName: String
    let os: String                      // "macos" | "linux" | "windows"
    let signingPublicKey: Data          // Ed25519 raw, 32 B
    let kxPublicKey: Data               // X25519 raw, 32 B
    let pairedAt: Date
}

struct DiscoveredPeer: Hashable {
    let peerID: String
    let displayName: String
    let os: String
    let endpoint: NetworkEndpointBox    // see below — wraps NWEndpoint for Hashable
    let protocolVersion: Int
}

/// Tiny wrapper so `DiscoveredPeer` can be `Hashable` even though `NWEndpoint`
/// itself isn't (in our build target, anyway). Compares by string description.
struct NetworkEndpointBox: Hashable {
    let underlying: AnyObject
    private let key: String
    init(_ endpoint: AnyObject) {
        self.underlying = endpoint
        self.key = String(describing: endpoint)
    }
    static func == (lhs: NetworkEndpointBox, rhs: NetworkEndpointBox) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

// MARK: - Identity store

final class ClipSyncIdentity: @unchecked Sendable {

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var sigPriv: Curve25519.Signing.PrivateKey?
        var kxPriv: Curve25519.KeyAgreement.PrivateKey?
        var peerID: String?
        var pairedPeers: [PairedPeer] = []
    }

    private static let keychainTag = "com.camndi.clipsync.identity.v1"
    private static let peerIDKey = "com.camndi.clipsync.deviceID"
    private static let pairedPeersKey = "com.camndi.clipsync.peers.v1"

    // MARK: - Lifecycle

    func loadOrCreate() {
        let id = ClipSyncIdentity.loadOrCreatePeerID()
        let (sigPriv, kxPriv) = ClipSyncIdentity.loadOrCreateKeys()
        let peers = ClipSyncIdentity.loadPairedPeers()
        lock.withLock {
            $0.peerID = id
            $0.sigPriv = sigPriv
            $0.kxPriv = kxPriv
            $0.pairedPeers = peers
        }
    }

    // MARK: - Accessors

    var peerID: String {
        lock.withLock { $0.peerID ?? "" }
    }

    var displayName: String {
        let raw = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let trimmed = raw.replacingOccurrences(of: ".local", with: "")
        return String(trimmed.prefix(ClipSync.maxDisplayNameLength))
    }

    var sigPub: Data {
        lock.withLock { $0.sigPriv?.publicKey.rawRepresentation ?? Data() }
    }

    var kxPub: Data {
        lock.withLock { $0.kxPriv?.publicKey.rawRepresentation ?? Data() }
    }

    /// Sign `message` with our Ed25519 long-term key.
    func sign(_ message: Data) throws -> Data {
        let key: Curve25519.Signing.PrivateKey? = lock.withLock { $0.sigPriv }
        guard let key else { throw ClipSyncError.invalidPeer }
        return try key.signature(for: message)
    }

    /// X25519 ECDH against our long-term static key. Returns 32-byte shared.
    func staticECDH(peerKxPub: Data) throws -> SymmetricKey {
        let key: Curve25519.KeyAgreement.PrivateKey? = lock.withLock { $0.kxPriv }
        guard let key else { throw ClipSyncError.invalidPeer }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKxPub)
        let shared = try key.sharedSecretFromKeyAgreement(with: peer)
        return shared.withUnsafeBytes { SymmetricKey(data: Data($0)) }
    }

    // MARK: - Paired peers

    var pairedPeers: [PairedPeer] {
        lock.withLock { $0.pairedPeers }
    }

    func paired(peerID: String) -> PairedPeer? {
        lock.withLock { $0.pairedPeers.first { $0.peerID == peerID } }
    }

    func upsert(pairedPeer: PairedPeer) {
        lock.withLock {
            if let idx = $0.pairedPeers.firstIndex(where: { $0.peerID == pairedPeer.peerID }) {
                $0.pairedPeers[idx] = pairedPeer
            } else {
                $0.pairedPeers.append(pairedPeer)
            }
            ClipSyncIdentity.savePairedPeers($0.pairedPeers)
        }
    }

    func remove(peerID: String) {
        lock.withLock {
            $0.pairedPeers.removeAll { $0.peerID == peerID }
            ClipSyncIdentity.savePairedPeers($0.pairedPeers)
        }
    }

    // MARK: - Fingerprint

    /// Format a 32-byte Ed25519 public key as `AB:CD:…:EF` (16 bytes of SHA-256, colon-hex).
    static func fingerprint(_ sigPub: Data) -> String {
        let hash = SHA256.hash(data: sigPub).prefix(16)
        return hash.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: - Persistence helpers

    private static func loadOrCreatePeerID() -> String {
        if let s = UserDefaults.standard.string(forKey: peerIDKey),
           UUID(uuidString: s) != nil {
            return s
        }
        let new = UUID().uuidString.lowercased()
        UserDefaults.standard.set(new, forKey: peerIDKey)
        return new
    }

    private static func loadOrCreateKeys() -> (Curve25519.Signing.PrivateKey, Curve25519.KeyAgreement.PrivateKey) {
        if let blob = keychainLoad(), blob.count == 64 {
            do {
                let sig = try Curve25519.Signing.PrivateKey(rawRepresentation: blob.prefix(32))
                let kx = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: blob.suffix(32))
                return (sig, kx)
            } catch {
                print("[CamNDI] ClipSync identity blob corrupt — regenerating: \(error)")
            }
        }
        let sig = Curve25519.Signing.PrivateKey()
        let kx = Curve25519.KeyAgreement.PrivateKey()
        var blob = Data()
        blob.append(sig.rawRepresentation)
        blob.append(kx.rawRepresentation)
        keychainSave(blob)
        return (sig, kx)
    }

    private static func loadPairedPeers() -> [PairedPeer] {
        guard let data = UserDefaults.standard.data(forKey: pairedPeersKey) else { return [] }
        do {
            return try JSONDecoder().decode([PairedPeer].self, from: data)
        } catch {
            print("[CamNDI] ClipSync paired peers blob corrupt — clearing: \(error)")
            return []
        }
    }

    private static func savePairedPeers(_ peers: [PairedPeer]) {
        do {
            let data = try JSONEncoder().encode(peers)
            UserDefaults.standard.set(data, forKey: pairedPeersKey)
        } catch {
            print("[CamNDI] ClipSync failed to persist paired peers: \(error)")
        }
    }

    // MARK: - Keychain wrappers

    private static func keychainLoad() -> Data? {
        let q: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     keychainTag,
            kSecAttrAccount as String:     "identity",
            kSecReturnData as String:      true,
            kSecMatchLimit as String:      kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecSuccess { return out as? Data }
        if status != errSecItemNotFound {
            print("[CamNDI] ClipSync keychain load: OSStatus \(status)")
        }
        return nil
    }

    private static func keychainSave(_ data: Data) {
        let baseQuery: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     keychainTag,
            kSecAttrAccount as String:     "identity",
        ]
        // Try update first; if not present, add.
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            print("[CamNDI] ClipSync keychain save: OSStatus \(status)")
        }
    }
}

// MARK: - Hello signature helpers

extension ClipSyncIdentity {

    /// Build the bytes that go into Ed25519.sign for a hello frame.
    /// `peerSigPubExpected` is the peer's sigPub when known (responder uses initiator's),
    /// or 32 zero bytes (initiator who doesn't yet know who they're talking to).
    static func helloSignedMessage(ephPub: Data, peerSigPubExpected: Data) -> Data {
        precondition(ephPub.count == 32 && peerSigPubExpected.count == 32)
        var msg = Data(capacity: ClipSync.helloDomain.count + 64)
        msg.append(ClipSync.helloDomain)
        msg.append(ephPub)
        msg.append(peerSigPubExpected)
        return msg
    }

    static let zero32 = Data(repeating: 0, count: 32)
}
