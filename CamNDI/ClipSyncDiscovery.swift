//
//  ClipSyncDiscovery.swift
//  CamNDI
//
//  mDNS advertise + browse for ClipSync v1 (`_clipsync._tcp`). Filters out our
//  own peerID and dedupes peers across multiple network interfaces.
//

import Foundation
import Network
import os

final class ClipSyncDiscovery: @unchecked Sendable {

    // Pulled-set of peers currently visible on the LAN.
    var onPeersChanged: (([DiscoveredPeer]) -> Void)?

    /// Endpoint of an incoming connection — the manager attaches a Connection wrapper.
    var onIncomingConnection: ((NWConnection) -> Void)?

    private let queue = DispatchQueue(label: "com.camndi.clipsync.io", qos: .utility)
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var peers: [String: DiscoveredPeer] = [:]    // keyed by peerID
        var listener: NWListener?
        var browser: NWBrowser?
        var advertisedPort: UInt16 = 0
    }

    private let identity: ClipSyncIdentity

    init(identity: ClipSyncIdentity) {
        self.identity = identity
    }

    var listenPort: UInt16 {
        lock.withLock { $0.advertisedPort }
    }

    func start() {
        startListener()
    }

    func stop() {
        let (l, b) = lock.withLock { (s: inout State) in
            let l = s.listener; let b = s.browser
            s.listener = nil; s.browser = nil; s.peers.removeAll()
            return (l, b)
        }
        l?.cancel()
        b?.cancel()
        onPeersChanged?([])
    }

    // MARK: - Listener (advertises _clipsync._tcp)

    private func startListener() {
        let txt: NWTXTRecord = makeTXTRecord()
        let service = NWListener.Service(name: identity.peerID,
                                         type: ClipSync.serviceType,
                                         domain: nil,
                                         txtRecord: txt)

        let params = NWParameters.tcp
        params.includePeerToPeer = true

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            print("[CamNDI] ClipSync listener init failed: \(error)")
            return
        }
        listener.service = service

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let p = listener.port?.rawValue {
                    self?.lock.withLock { $0.advertisedPort = p }
                    print("[CamNDI] ClipSync listening on TCP \(p), advertising \(ClipSync.serviceType) as \(self?.identity.peerID ?? "?")")
                    self?.startBrowser()
                }
            case .failed(let err):
                print("[CamNDI] ClipSync listener failed: \(err)")
            case .cancelled:
                break
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            self?.onIncomingConnection?(conn)
        }

        lock.withLock { $0.listener = listener }
        listener.start(queue: queue)
    }

    private func makeTXTRecord() -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt["id"] = identity.peerID
        txt["name"] = identity.displayName
        txt["os"] = ClipSync.osIdentifier
        txt["v"] = String(ClipSync.protocolVersion)
        return txt
    }

    // MARK: - Browser

    private func startBrowser() {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: ClipSync.serviceType, domain: nil)
        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(for: descriptor, using: params)
        browser.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                print("[CamNDI] ClipSync browser failed: \(err)")
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results: results)
        }

        lock.withLock { $0.browser = browser }
        browser.start(queue: queue)
    }

    private func handle(results: Set<NWBrowser.Result>) {
        var collected: [String: DiscoveredPeer] = [:]

        for r in results {
            guard case let .bonjour(txt) = r.metadata else { continue }
            guard let id = txt["id"], id != identity.peerID else { continue }    // skip self

            let name = txt["name"] ?? id
            let os = txt["os"] ?? "unknown"
            let v = Int(txt["v"] ?? "1") ?? 1

            let endpoint = r.endpoint

            // Dedupe by peerID; if already present, prefer Bonjour endpoint over ip-port.
            if collected[id] == nil {
                collected[id] = DiscoveredPeer(
                    peerID: id,
                    displayName: name,
                    os: os,
                    endpoint: NetworkEndpointBox(endpoint as AnyObject),
                    protocolVersion: v
                )
            }
        }

        let nextPeers = collected
        let prev = lock.withLock { (s: inout State) -> [String: DiscoveredPeer] in
            let p = s.peers
            s.peers = nextPeers
            return p
        }

        if prev.keys != nextPeers.keys || prev != nextPeers {
            let list = Array(nextPeers.values).sorted { $0.displayName < $1.displayName }
            onPeersChanged?(list)
        }
    }

    /// Resolve a `DiscoveredPeer` back to an `NWEndpoint` suitable for `NWConnection`.
    static func endpoint(of peer: DiscoveredPeer) -> NWEndpoint? {
        peer.endpoint.underlying as? NWEndpoint
    }
}
