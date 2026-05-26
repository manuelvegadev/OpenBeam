//
//  ClipSyncConnection.swift
//  Open Beam
//
//  One TCP NWConnection per peer. Owns the cleartext hello handshake, the
//  ECDH+HKDF session-key derivation, the ChaCha20-Poly1305 frame seal/open,
//  and routes both control and encrypted payloads up to the connection's
//  delegate (the manager).
//

import Foundation
import Network
import CryptoKit
import os

private let connLog = Logger(subsystem: "com.openbeam.clipsync", category: "connection")

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

protocol ClipSyncConnectionDelegate: AnyObject {
    /// Handshake completed. Includes whether the peer is currently paired and
    /// the verification artifacts available during this handshake (used by the
    /// pairing flow to display the 6-digit code + fingerprint).
    func connection(_ c: ClipSyncConnection,
                    didCompleteHandshakeWith peerHello: HelloFrame,
                    isPaired: Bool,
                    verificationCode: String,
                    fingerprint: String)

    /// A `pair_request` arrived from an unpaired peer. Delegate is responsible
    /// for showing the user dialog and calling `acceptPair(...)` or `rejectPair(...)`.
    func connection(_ c: ClipSyncConnection,
                    didReceivePairRequest req: PairRequestFrame,
                    verificationCode: String,
                    fingerprint: String)

    /// Peer responded to our outbound pair request.
    func connection(_ c: ClipSyncConnection, didReceivePairAccept ack: PairAcceptFrame)
    func connection(_ c: ClipSyncConnection, didReceivePairReject rej: PairRejectFrame)

    /// Decrypted JSON plaintext arrived. The delegate routes by `kind`.
    func connection(_ c: ClipSyncConnection, didReceivePayload data: Data)

    /// Connection ended (gracefully or with error).
    func connectionDidClose(_ c: ClipSyncConnection, error: Error?)
}

final class ClipSyncConnection: @unchecked Sendable {

    enum Role { case initiator, responder }
    enum HandshakeState { case awaitingPeerHello, paired, unpaired, closed }

    let role: Role
    weak var delegate: ClipSyncConnectionDelegate?

    /// Resolved peer info, valid after handshake.
    private(set) var peerHello: HelloFrame?
    var peerID: String? { peerHello?.peerID }

    private let identity: ClipSyncIdentity
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.openbeam.clipsync.io", qos: .utility)
    private let decoder = ClipSyncFraming.Decoder()

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var handshake: HandshakeState = .awaitingPeerHello
        var ephPriv: Curve25519.KeyAgreement.PrivateKey?
        var ephPub: Data = Data()
        var sessionKey: SymmetricKey?
        var sendCounter: UInt64 = 0
        var recvCounter: UInt64 = 0          // last accepted; next must be > this
        var recvHasCounter: Bool = false
        var sharedEph: SymmetricKey?         // kept until pair is decided (for verify code)
        var sharedStatic: SymmetricKey?      // ditto
    }

    // MARK: - Init

    init(role: Role, connection: NWConnection, identity: ClipSyncIdentity) {
        self.role = role
        self.connection = connection
        self.identity = identity
    }

    // MARK: - Lifecycle

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state: state)
        }
        connection.start(queue: queue)
    }

    func cancel() {
        lock.withLock { $0.handshake = .closed }
        connection.cancel()
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            sendHello()
            scheduleReceive()
        case .failed(let err):
            close(with: err)
        case .cancelled:
            close(with: nil)
        default:
            break
        }
    }

    // MARK: - Sending

    private func sendHello() {
        // Generate ephemeral X25519 keypair for this connection.
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let ephPub = eph.publicKey.rawRepresentation
        lock.withLock {
            $0.ephPriv = eph
            $0.ephPub = ephPub
        }

        // Initiator doesn't know who the peer is yet -> sign with zeros.
        let peerExpected = ClipSyncIdentity.zero32
        let toSign = ClipSyncIdentity.helloSignedMessage(ephPub: ephPub, peerSigPubExpected: peerExpected)
        guard let sig = try? identity.sign(toSign) else {
            close(with: ClipSyncError.signatureInvalid)
            return
        }

        let hello = HelloFrame(
            v: ClipSync.protocolVersion,
            type: ControlFrameType.hello.rawValue,
            peerID: identity.peerID,
            displayName: identity.displayName,
            os: ClipSync.osIdentifier,
            sigPub: identity.sigPub,
            kxPub: identity.kxPub,
            ephPub: ephPub,
            sig: sig
        )
        send(codable: hello)
    }

    func send(codable: some Encodable) {
        do {
            let body = try ClipSyncJSON.encoder.encode(codable)
            let framed = ClipSyncFraming.wrap(body)
            connection.send(content: framed, completion: .contentProcessed { [weak self] err in
                if let err { self?.close(with: err) }
            })
        } catch {
            close(with: error)
        }
    }

    /// Encrypt + send a JSON-encoded payload. Returns false if not in
    /// `paired` state.
    @discardableResult
    func sendEncrypted(payload: Data) -> Bool {
        let (key, n, dirByte): (SymmetricKey?, UInt64, UInt8) = lock.withLock { s in
            guard s.handshake == .paired, let key = s.sessionKey else {
                return (nil, 0, 0)
            }
            let n = s.sendCounter
            s.sendCounter &+= 1
            let dir: UInt8 = (role == .initiator) ? 0x00 : 0x01
            return (key, n, dir)
        }
        guard let key else { return false }

        var nonceBytes = Data(count: 12)
        nonceBytes[0] = dirByte
        var nBE = n.bigEndian
        withUnsafeBytes(of: &nBE) { raw in
            for i in 0..<8 { nonceBytes[1 + i] = raw[i] }
        }

        do {
            let nonce = try ChaChaPoly.Nonce(data: nonceBytes)
            let sealed = try ChaChaPoly.seal(payload, using: key, nonce: nonce)
            // Per spec, ct = ciphertext || 16-byte tag. Sealed.combined is
            // nonce || ciphertext || tag, so we want sealed.ciphertext + sealed.tag.
            var ct = Data()
            ct.append(sealed.ciphertext)
            ct.append(sealed.tag)
            let env = EncryptedFrame(
                v: ClipSync.protocolVersion,
                type: ControlFrameType.encrypted.rawValue,
                n: n,
                ct: ct
            )
            send(codable: env)
            return true
        } catch {
            close(with: error)
            return false
        }
    }

    // MARK: - Receiving

    private func scheduleReceive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    self.decoder.append(data)
                    while let frame = try self.decoder.nextFrame() {
                        try self.dispatch(frame: frame)
                    }
                } catch {
                    self.close(with: error)
                    return
                }
            }
            if isComplete {
                self.close(with: nil)
                return
            }
            if let error {
                self.close(with: error)
                return
            }
            self.scheduleReceive()
        }
    }

    private func dispatch(frame: Data) throws {
        guard let type = ClipSyncJSON.peekType(frame) else {
            throw ClipSyncError.malformedFrame("missing or unknown type")
        }

        switch type {
        case .hello:
            let hello = try ClipSyncJSON.decoder.decode(HelloFrame.self, from: frame)
            try handleHello(hello)
        case .pairRequest:
            let req = try ClipSyncJSON.decoder.decode(PairRequestFrame.self, from: frame)
            try handlePairRequest(req)
        case .pairAccept:
            let ack = try ClipSyncJSON.decoder.decode(PairAcceptFrame.self, from: frame)
            delegate?.connection(self, didReceivePairAccept: ack)
        case .pairReject:
            let rej = try ClipSyncJSON.decoder.decode(PairRejectFrame.self, from: frame)
            delegate?.connection(self, didReceivePairReject: rej)
        case .encrypted:
            let env = try ClipSyncJSON.decoder.decode(EncryptedFrame.self, from: frame)
            try handleEncrypted(env)
        }
    }

    // MARK: - Handshake

    private func handleHello(_ peerHello: HelloFrame) throws {
        guard peerHello.v == ClipSync.protocolVersion else {
            throw ClipSyncError.versionMismatch(peerHello.v)
        }
        guard peerHello.sigPub.count == 32, peerHello.kxPub.count == 32, peerHello.ephPub.count == 32, peerHello.sig.count == 64 else {
            throw ClipSyncError.malformedFrame("hello key/sig sizes")
        }

        // What did the peer expect for our sigPub?
        // - If we sent first (we're the initiator), peer's hello arrives second
        //   and the peer should have used our actual sigPub.
        // - If we sent second (we're the responder), peer's hello arrives first
        //   and the peer used zeros.
        let peerExpectedOurSigPub: Data = (role == .initiator) ? identity.sigPub : ClipSyncIdentity.zero32
        let signedMsg = ClipSyncIdentity.helloSignedMessage(
            ephPub: peerHello.ephPub,
            peerSigPubExpected: peerExpectedOurSigPub
        )

        let peerSigKey = try Curve25519.Signing.PublicKey(rawRepresentation: peerHello.sigPub)
        guard peerSigKey.isValidSignature(peerHello.sig, for: signedMsg) else {
            connLog.error("hello sig verify FAILED, role=\(self.role == .responder ? "responder" : "initiator", privacy: .public)")
            connLog.error("  expected_signed_msg(hex)=\(signedMsg.hex, privacy: .public)")
            connLog.error("  expected_signed_msg_len=\(signedMsg.count, privacy: .public)")
            connLog.error("  peer_ephPub(hex)=\(peerHello.ephPub.hex, privacy: .public)")
            connLog.error("  peer_sigPub(hex)=\(peerHello.sigPub.hex, privacy: .public)")
            connLog.error("  peer_expected_our_sigPub(hex)=\(peerExpectedOurSigPub.hex, privacy: .public)")
            connLog.error("  signature(hex)=\(peerHello.sig.hex, privacy: .public)")
            connLog.error("  domain(hex)=\(ClipSync.helloDomain.hex, privacy: .public)")
            throw ClipSyncError.signatureInvalid
        }
        connLog.info("hello sig verified for peer=\(peerHello.peerID, privacy: .public)")

        // If peer is in our pinned list, the sigPub must match the pinned value.
        let isPaired: Bool
        if let pinned = identity.paired(peerID: peerHello.peerID) {
            if pinned.signingPublicKey != peerHello.sigPub {
                throw ClipSyncError.identityMismatch
            }
            isPaired = true
        } else {
            isPaired = false
        }

        // Derive shared secrets and session key.
        let ephPriv: Curve25519.KeyAgreement.PrivateKey? = lock.withLock { $0.ephPriv }
        guard let ephPriv else { throw ClipSyncError.invalidPeer }

        let peerEphKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerHello.ephPub)
        let sharedEph = try ephPriv.sharedSecretFromKeyAgreement(with: peerEphKey)
        let sharedStatic = try identity.staticECDH(peerKxPub: peerHello.kxPub)

        let sharedEphData: Data = sharedEph.withUnsafeBytes { Data($0) }
        let sharedStaticData: Data = sharedStatic.withUnsafeBytes { Data($0) }

        var ikm = Data(capacity: 64)
        ikm.append(sharedEphData)
        ikm.append(sharedStaticData)

        let myEph: Data = lock.withLock { $0.ephPub }
        let salt = sortedConcat(myEph, peerHello.ephPub)

        let sessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: ClipSync.sessionInfo,
            outputByteCount: 32
        )

        // Derive verification code (6-digit decimal) for pairing UX.
        let verifyBytes = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: ClipSync.pairVerifyInfo,
            outputByteCount: 4
        )
        let codeNumber = verifyBytes.withUnsafeBytes { raw -> UInt32 in
            raw.load(as: UInt32.self).bigEndian
        } % 1_000_000
        let verificationCode = String(format: "%06u", codeNumber)
        let fingerprint = ClipSyncIdentity.fingerprint(peerHello.sigPub)

        lock.withLock {
            $0.sessionKey = sessionKey
            $0.sharedEph = SymmetricKey(data: sharedEphData)
            $0.sharedStatic = SymmetricKey(data: sharedStaticData)
            $0.handshake = isPaired ? .paired : .unpaired
        }
        self.peerHello = peerHello

        delegate?.connection(self,
                             didCompleteHandshakeWith: peerHello,
                             isPaired: isPaired,
                             verificationCode: verificationCode,
                             fingerprint: fingerprint)
    }

    private func handlePairRequest(_ req: PairRequestFrame) throws {
        let state = lock.withLock { $0.handshake }
        guard state == .unpaired else {
            // Already paired — ignore (KDE-Connect-style "re-pair" not in v1).
            return
        }
        guard let peerHello else { throw ClipSyncError.malformedFrame("pair_request before hello") }
        guard req.peerID == peerHello.peerID, req.sigPub == peerHello.sigPub, req.kxPub == peerHello.kxPub else {
            throw ClipSyncError.identityMismatch
        }
        // Re-derive verification code (same as handshake).
        let (sharedEph, sharedStatic, myEph): (SymmetricKey?, SymmetricKey?, Data) = lock.withLock { ($0.sharedEph, $0.sharedStatic, $0.ephPub) }
        guard let sharedEph, let sharedStatic else { throw ClipSyncError.invalidPeer }
        let ephData: Data = sharedEph.withUnsafeBytes { Data($0) }
        let stData: Data = sharedStatic.withUnsafeBytes { Data($0) }
        var ikm = Data(); ikm.append(ephData); ikm.append(stData)
        let salt = sortedConcat(myEph, peerHello.ephPub)
        let verifyBytes = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: ClipSync.pairVerifyInfo,
            outputByteCount: 4
        )
        let code = verifyBytes.withUnsafeBytes { raw in
            raw.load(as: UInt32.self).bigEndian
        } % 1_000_000

        delegate?.connection(self,
                             didReceivePairRequest: req,
                             verificationCode: String(format: "%06u", code),
                             fingerprint: ClipSyncIdentity.fingerprint(req.sigPub))
    }

    private func handleEncrypted(_ env: EncryptedFrame) throws {
        let (key, lastN, hasN, dirByte): (SymmetricKey?, UInt64, Bool, UInt8) = lock.withLock { s in
            // Receiver direction byte = opposite of our send direction.
            let dir: UInt8 = (role == .initiator) ? 0x01 : 0x00
            return (s.sessionKey, s.recvCounter, s.recvHasCounter, dir)
        }
        guard let key else { throw ClipSyncError.invalidPeer }

        if hasN, env.n <= lastN { throw ClipSyncError.nonceReplay(env.n) }
        if !hasN, env.n != 0 { throw ClipSyncError.nonceReplay(env.n) }    // expect first to be 0

        var nonceBytes = Data(count: 12)
        nonceBytes[0] = dirByte
        var nBE = env.n.bigEndian
        withUnsafeBytes(of: &nBE) { raw in
            for i in 0..<8 { nonceBytes[1 + i] = raw[i] }
        }

        guard env.ct.count >= 16 else { throw ClipSyncError.malformedFrame("ciphertext too small") }
        let tag = env.ct.suffix(16)
        let ciphertext = env.ct.prefix(env.ct.count - 16)

        do {
            let nonce = try ChaChaPoly.Nonce(data: nonceBytes)
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let plain = try ChaChaPoly.open(box, using: key)
            lock.withLock {
                $0.recvCounter = env.n
                $0.recvHasCounter = true
            }
            delegate?.connection(self, didReceivePayload: plain)
        } catch {
            throw ClipSyncError.decryptFailed
        }
    }

    // MARK: - Pair-flow API (called from manager / pairing coordinator)

    func sendPairRequest() {
        let req = PairRequestFrame(
            v: ClipSync.protocolVersion,
            type: ControlFrameType.pairRequest.rawValue,
            peerID: identity.peerID,
            displayName: identity.displayName,
            os: ClipSync.osIdentifier,
            sigPub: identity.sigPub,
            kxPub: identity.kxPub
        )
        send(codable: req)
    }

    func sendPairAccept() {
        let ack = PairAcceptFrame(
            v: ClipSync.protocolVersion,
            type: ControlFrameType.pairAccept.rawValue,
            peerID: identity.peerID,
            displayName: identity.displayName,
            os: ClipSync.osIdentifier,
            sigPub: identity.sigPub,
            kxPub: identity.kxPub
        )
        send(codable: ack)
    }

    func sendPairReject(reason: String) {
        let rej = PairRejectFrame(
            v: ClipSync.protocolVersion,
            type: ControlFrameType.pairReject.rawValue,
            reason: reason
        )
        send(codable: rej)
    }

    /// Promote an `unpaired` connection to `paired` after both sides confirm
    /// (the manager calls this after persisting the peer).
    func markPaired() {
        lock.withLock {
            if $0.handshake == .unpaired { $0.handshake = .paired }
        }
    }

    // MARK: - Close

    private func close(with error: Error?) {
        let already: Bool = lock.withLock {
            if $0.handshake == .closed { return true }
            $0.handshake = .closed
            return false
        }
        guard !already else { return }
        connection.cancel()
        delegate?.connectionDidClose(self, error: error)
    }
}

// MARK: - Helpers

private func sortedConcat(_ a: Data, _ b: Data) -> Data {
    if a.lexicographicallyPrecedes(b) {
        var out = Data(); out.append(a); out.append(b); return out
    } else {
        var out = Data(); out.append(b); out.append(a); return out
    }
}

private extension Data {
    func lexicographicallyPrecedes(_ other: Data) -> Bool {
        let n = Swift.min(count, other.count)
        for i in 0..<n {
            let l = self[startIndex + i]
            let r = other[other.startIndex + i]
            if l != r { return l < r }
        }
        return count < other.count
    }
}
