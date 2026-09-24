//
//  ClipSyncManager.swift
//  OpenBeam
//
//  Top-level coordinator for ClipSync: owns identity + discovery + plugins,
//  manages live connections per peer, exposes the menu-facing API.
//

import AppKit
import Foundation
import Network
import os

private let mgrLog = Logger(subsystem: "com.openbeam.clipsync", category: "manager")

final class ClipSyncManager: NSObject, @unchecked Sendable {

    // MARK: - Dependencies

    private let identity = ClipSyncIdentity()
    let preferences = ClipSyncPreferences()
    private let discovery: ClipSyncDiscovery
    private let clipboard: ClipboardPlugin
    private let share: SharePlugin
    private let ioQueue = DispatchQueue(label: "com.openbeam.clipsync.io", qos: .utility)

    // MARK: - Public state

    var isEnabled: Bool {
        get { lock.withLock { $0.isEnabled } }
        set {
            let changed: Bool = lock.withLock {
                guard $0.isEnabled != newValue else { return false }
                $0.isEnabled = newValue
                return true
            }
            guard changed else { return }
            preferences.setEnabled(newValue)    // survives the next launch
            onStateChanged?()
        }
    }

    var pairedPeers: [PairedPeer] { identity.pairedPeers }
    var discoveredPeers: [DiscoveredPeer] { lock.withLock { $0.discoveredPeers } }

    /// Fires when the menu should refresh.
    var onStateChanged: (() -> Void)?
    /// Fires when pairing UI — either end's — is about to display, so the menu
    /// can collapse out from under it.
    var onPairRequestPresented: (() -> Void)?

    // MARK: - Private state

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var isEnabled: Bool = false
        var discoveredPeers: [DiscoveredPeer] = []
        /// Persistent encrypted sessions keyed by peerID.
        var sessions: [String: ClipSyncConnection] = [:]
        /// Pairing-only connections (no peerID until handshake completes).
        var pairing: [ObjectIdentifier: ClipSyncConnection] = [:]
        /// Outbound session dials in flight, and the peer each is for: at most one
        /// per peer, to prevent thrash. Keyed by connection because a dial that
        /// fails before its handshake has no peerID of its own to clear it by.
        var dialing: [ObjectIdentifier: String] = [:]
    }

    // MARK: - Init

    override init() {
        identity.loadOrCreate()
        self.discovery = ClipSyncDiscovery(identity: identity)
        self.clipboard = ClipboardPlugin(identity: identity, preferences: preferences, queue: ioQueue)
        self.share = SharePlugin(identity: identity,
                                 clipboardPlugin: clipboard,
                                 preferences: preferences,
                                 queue: ioQueue)
        super.init()

        // Wire plugins to broadcast through this manager.
        self.clipboard.broadcast = { [weak self] payload in
            self?.broadcast(payloadData: payload)
        }
        self.share.broadcast = { [weak self] payload in
            self?.broadcast(payloadData: payload)
        }

        // Wire discovery callbacks.
        self.discovery.onPeersChanged = { [weak self] peers in
            guard let self else { return }
            self.lock.withLock { $0.discoveredPeers = peers }
            DispatchQueue.main.async { self.onStateChanged?() }
        }
        self.discovery.onIncomingConnection = { [weak self] nwc in
            self?.adopt(connection: nwc, role: .responder)
        }
    }

    // MARK: - Lifecycle

    func start() {
        discovery.start()
        clipboard.start()
        // Once discovery surfaces a paired peer, dial it lazily on first outbound.
        // The toggle is whatever the user last set it to; a machine that has
        // never been asked starts on as soon as it has someone to sync with.
        isEnabled = preferences.enabled ?? !identity.pairedPeers.isEmpty
    }

    func stop() {
        discovery.stop()
        clipboard.stop()

        let (sessions, pairing) = lock.withLock { (s: inout State) -> ([ClipSyncConnection], [ClipSyncConnection]) in
            let a = Array(s.sessions.values)
            let b = Array(s.pairing.values)
            s.sessions.removeAll()
            s.pairing.removeAll()
            return (a, b)
        }
        for c in sessions { c.cancel() }
        for c in pairing { c.cancel() }
    }

    // MARK: - Menu-facing API

    /// User picked a discovered peer to pair with.
    func requestPair(with peer: DiscoveredPeer) {
        guard let endpoint = ClipSyncDiscovery.endpoint(of: peer) else { return }

        // Simultaneous-pair tie-breaker: if the peer's ID is smaller, wait for them.
        if identity.peerID > peer.peerID {
            // Lex-smaller peer initiates; we wait. (We may also receive their pair_request.)
            // Open anyway — the other side will see ours and similarly defer; the smaller-ID
            // side wins. This branch keeps both apps responsive.
        }

        let nwc = NWConnection(to: endpoint, using: Self.dialParameters)
        adopt(connection: nwc, role: .initiator, intent: .pair)
    }

    /// User chose to forget a paired peer.
    func unpair(peerID: String) {
        identity.remove(peerID: peerID)

        // Tear down the session connection if any.
        let session: ClipSyncConnection? = lock.withLock { $0.sessions.removeValue(forKey: peerID) }
        session?.cancel()

        DispatchQueue.main.async { self.onStateChanged?() }
    }

    // MARK: - Connection lifecycle

    private enum Intent { case session, pair }

    private func adopt(connection nwc: NWConnection, role: ClipSyncConnection.Role, intent: Intent = .session) {
        let conn = makeConnection(nwc, role: role, intent: intent)
        // Every connection starts in the pairing bucket; the handshake moves it
        // to sessions once it identifies a paired peer.
        lock.withLock { $0.pairing[ObjectIdentifier(conn)] = conn }
        conn.start()
    }

    private func makeConnection(_ nwc: NWConnection, role: ClipSyncConnection.Role, intent: Intent) -> ClipSyncConnection {
        let conn = ClipSyncConnection(role: role,
                                      connection: nwc,
                                      identity: identity,
                                      userInitiatedPair: intent == .pair)
        conn.delegate = self
        return conn
    }

    private func openSessionIfNeeded(for peer: PairedPeer) {
        let existing: ClipSyncConnection? = lock.withLock { $0.sessions[peer.peerID] }
        if existing != nil { return }
        // Find a discovered endpoint for this peer.
        guard let discovered = (lock.withLock { $0.discoveredPeers }.first { $0.peerID == peer.peerID }),
              let endpoint = ClipSyncDiscovery.endpoint(of: discovered) else {
            return    // peer offline; will retry on next outbound when discovered
        }
        let conn = makeConnection(NWConnection(to: endpoint, using: Self.dialParameters), role: .initiator, intent: .session)
        // Claimed and registered in one step, before it starts, so no other
        // caller dials the same peer and no close can arrive unaccounted for.
        let claimed: Bool = lock.withLock { state in
            guard !state.dialing.values.contains(peer.peerID) else { return false }
            state.dialing[ObjectIdentifier(conn)] = peer.peerID
            state.pairing[ObjectIdentifier(conn)] = conn
            return true
        }
        guard claimed else { return }
        conn.start()
    }

    /// TCP that gives up on a connect after 5 s. The default waits over a minute
    /// on a network that drops packets for a closed port, with anything queued
    /// for that peer stuck behind it.
    private static var dialParameters: NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        return NWParameters(tls: nil, tcp: tcp)
    }

    /// Encrypt + send `payloadData` (plaintext JSON bytes) on every paired+ready connection.
    /// Lazily opens connections to known paired peers we have a discovered endpoint for.
    private func broadcast(payloadData: Data) {
        guard isEnabled else { return }

        // Open lazy sessions for paired peers we don't yet have a connection to.
        for peer in identity.pairedPeers {
            openSessionIfNeeded(for: peer)
        }

        let sessions: [ClipSyncConnection] = lock.withLock { Array($0.sessions.values) }
        for c in sessions {
            c.sendEncrypted(payload: payloadData)
        }
    }
}

// MARK: - ClipSyncConnectionDelegate

extension ClipSyncManager: ClipSyncConnectionDelegate {

    func connection(_ c: ClipSyncConnection,
                    didCompleteHandshakeWith peerHello: HelloFrame,
                    isPaired: Bool,
                    verificationCode: String,
                    fingerprint: String) {
        if isPaired {
            // Move into session bucket keyed by peerID. If there's already one, replace it.
            let oldSession: ClipSyncConnection? = lock.withLock { (s: inout State) -> ClipSyncConnection? in
                let prev = s.sessions[peerHello.peerID]
                s.sessions[peerHello.peerID] = c
                s.pairing.removeValue(forKey: ObjectIdentifier(c))
                s.dialing.removeValue(forKey: ObjectIdentifier(c))
                return prev
            }
            oldSession?.cancel()

            // Send a snapshot of the current text clipboard (if any), only while
            // syncing: the other side can open a session with this one either way.
            if isEnabled {
                clipboard.sendSnapshot { [weak c] payload in
                    c?.sendEncrypted(payload: payload)
                }
            }
        } else {
            // Connection waits for a pair_request (responder) or sends one (initiator).
            guard c.role == .initiator else { return }
            c.sendPairRequest()

            // Show the user the code the other device is about to ask them to
            // confirm — only for a pair the user asked for, never for a session
            // dial that happened to find an unpaired peer.
            guard c.userInitiatedPair else { return }
            DispatchQueue.main.async { [weak self, weak c] in
                guard let self, let c else { return }
                self.onPairRequestPresented?()
                ClipSyncPairing.presentAsking(
                    token: ObjectIdentifier(c),
                    displayName: peerHello.displayName,
                    verificationCode: verificationCode,
                    fingerprint: fingerprint
                ) { [weak c] in c?.cancel() }
            }
        }
    }

    func connection(_ c: ClipSyncConnection,
                    didReceivePairRequest req: PairRequestFrame,
                    verificationCode: String,
                    fingerprint: String) {
        // Already trusted: the hello on this connection was verified against
        // the key we pinned for them, so the request can only come from the
        // peer we paired with — they just lost their half. Answer without
        // making the user confirm a device they already confirmed once.
        if identity.paired(peerID: req.peerID) != nil {
            mgrLog.info("pair_request from an already-paired peer=\(req.peerID, privacy: .public) — re-accepting")
            c.sendPairAccept()
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onPairRequestPresented?()
            ClipSyncPairing.presentAnswering(
                token: ObjectIdentifier(c),
                displayName: req.displayName,
                verificationCode: verificationCode,
                fingerprint: fingerprint
            ) { decision in
                self.ioQueue.async {
                    self.handlePairDecision(decision, for: c, req: req)
                }
            }
        }
    }

    func connection(_ c: ClipSyncConnection, didReceivePairAccept ack: PairAcceptFrame) {
        // Validate that ack.peerID matches the peerID we saw in hello.
        guard let peerHello = c.peerHello,
              ack.peerID == peerHello.peerID,
              ack.sigPub == peerHello.sigPub,
              ack.kxPub == peerHello.kxPub else {
            print("[OpenBeam] ClipSync pair_accept identity mismatch — aborting")
            resolvePanel(for: c, outcome: .failed)
            c.cancel()
            return
        }

        identity.upsert(pairedPeer: PairedPeer(
            peerID: ack.peerID,
            displayName: ack.displayName,
            os: ack.os,
            signingPublicKey: ack.sigPub,
            kxPublicKey: ack.kxPub,
            pairedAt: Date()
        ))

        // Auto-enable on first pair.
        let firstPair = identity.pairedPeers.count == 1
        if firstPair { isEnabled = true }
        DispatchQueue.main.async { self.onStateChanged?() }
        resolvePanel(for: c, outcome: .accepted)

        // Pairing connection: close and re-open as a session. (Spec says reopen
        // for clean state-machine separation.)
        c.cancel()
    }

    func connection(_ c: ClipSyncConnection, didReceivePairReject rej: PairRejectFrame) {
        print("[OpenBeam] ClipSync pair_reject: \(rej.reason)")
        resolvePanel(for: c, outcome: .rejected(rej.reason))
        c.cancel()
    }

    func connection(_ c: ClipSyncConnection, didReceivePayload data: Data) {
        guard let kind = ClipSyncJSON.peekKind(data) else {
            mgrLog.error("recv: payload missing/unknown 'kind'; \(data.count, privacy: .public) bytes")
            return
        }
        mgrLog.info("recv: kind=\(kind, privacy: .public), \(data.count, privacy: .public) bytes from peer=\(c.peerID ?? "?", privacy: .public)")
        switch kind {
        // With syncing off, a peer that still has it on can open a session with
        // this one; what it sends must not land on this clipboard.
        case "clipboard.text", "clipboard.text.snapshot":
            guard isEnabled else { return }
            clipboard.handleInbound(payloadData: data)
        case "share.begin", "share.chunk", "share.end", "share.cancel":
            guard isEnabled else { return }
            share.handleInbound(payloadData: data, kind: kind)
        case "ping":
            if let ping = try? ClipSyncJSON.decoder.decode(PingPayload.self, from: data) {
                let pong = PingPayload(kind: "pong", nonce: ping.nonce)
                if let d = try? ClipSyncJSON.encoder.encode(pong) {
                    c.sendEncrypted(payload: d)
                }
            }
        case "pong":
            break
        default:
            mgrLog.info("recv: ignoring unknown kind=\(kind, privacy: .public)")
        }
    }

    func connectionDidClose(_ c: ClipSyncConnection, error: Error?) {
        if let error {
            print("[OpenBeam] ClipSync connection closed with error: \(error)")
        }
        lock.withLock { state in
            let dialedPeer = state.dialing.removeValue(forKey: ObjectIdentifier(c))
            let peerID = c.peerID ?? dialedPeer
            state.pairing.removeValue(forKey: ObjectIdentifier(c))
            if let peerID, state.sessions[peerID] === c {
                state.sessions.removeValue(forKey: peerID)
            }
        }
        // A pair that ended without an answer: say so rather than leave the
        // panel spinning. Accept and reject already resolved their own panel,
        // and the token check drops this one.
        resolvePanel(for: c, outcome: .failed)
    }

    /// Hand an outcome to this connection's pairing window, if it has one.
    private func resolvePanel(for c: ClipSyncConnection,
                              outcome: ClipSyncPairing.Outcome) {
        let token = ObjectIdentifier(c)
        DispatchQueue.main.async {
            ClipSyncPairing.resolve(token: token, outcome: outcome)
        }
    }

    // MARK: - Pair decision

    private func handlePairDecision(_ decision: ClipSyncPairing.Decision,
                                    for c: ClipSyncConnection,
                                    req: PairRequestFrame) {
        switch decision {
        case .accept:
            identity.upsert(pairedPeer: PairedPeer(
                peerID: req.peerID,
                displayName: req.displayName,
                os: req.os,
                signingPublicKey: req.sigPub,
                kxPublicKey: req.kxPub,
                pairedAt: Date()
            ))
            let firstPair = identity.pairedPeers.count == 1
            if firstPair { isEnabled = true }
            // `sendPairAccept` closes once the frame is out, per spec —
            // sessions reconnect on demand.
            c.sendPairAccept()
            DispatchQueue.main.async { self.onStateChanged?() }
        case .reject(let reason):
            c.sendPairReject(reason: reason)
        }
    }
}
