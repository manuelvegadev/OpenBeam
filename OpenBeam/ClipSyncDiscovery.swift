//
//  ClipSyncDiscovery.swift
//  Open Beam
//
//  mDNS advertise + browse for ClipSync v1 (`_clipsync._tcp`). Filters out our
//  own peerID and dedupes peers across multiple network interfaces.
//
//  TCP listening uses NWListener; mDNS publish + browse goes through the
//  legacy `dns_sd.h` API (see ClipSyncBonjour.swift) to bypass macOS 15+'s
//  NWListener.publish gating that hits ad-hoc-signed dev builds with NoAuth.
//

import Foundation
import Network
import os

private let log = Logger(subsystem: "com.openbeam.clipsync", category: "discovery")

final class ClipSyncDiscovery: @unchecked Sendable {

    var onPeersChanged: (([DiscoveredPeer]) -> Void)?
    var onIncomingConnection: ((NWConnection) -> Void)?

    private let queue = DispatchQueue(label: "com.openbeam.clipsync.io", qos: .utility)
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var peers: [String: DiscoveredPeer] = [:]    // keyed by peerID
        var listener: NWListener?
        var advertisedPort: UInt16 = 0
    }

    private let identity: ClipSyncIdentity
    private let publisher = BonjourPublisher()
    private let browser: BonjourBrowser

    init(identity: ClipSyncIdentity) {
        self.identity = identity
        self.browser = BonjourBrowser(queue: queue)
    }

    var listenPort: UInt16 {
        lock.withLock { $0.advertisedPort }
    }

    func start() {
        startListener()
    }

    func stop() {
        let l: NWListener? = lock.withLock { (s: inout State) in
            let l = s.listener
            s.listener = nil
            s.peers.removeAll()
            return l
        }
        l?.cancel()
        publisher.stop()
        browser.stop()
        onPeersChanged?([])
    }

    // MARK: - TCP listener (no Bonjour service attached)

    private func startListener() {
        let params = NWParameters.tcp

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            log.error("listener init failed: \(String(describing: error), privacy: .public)")
            return
        }

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .setup:
                log.info("listener: setup")
            case .waiting(let err):
                log.error("listener: waiting (transient): \(String(describing: err), privacy: .public)")
            case .ready:
                if let p = listener.port?.rawValue {
                    self?.lock.withLock { $0.advertisedPort = p }
                    log.info("listener: ready on TCP \(p, privacy: .public)")
                    self?.advertise(port: p)
                    self?.startBrowse()
                }
            case .failed(let err):
                log.error("listener: failed: \(String(describing: err), privacy: .public)")
            case .cancelled:
                log.info("listener: cancelled")
            @unknown default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            self?.onIncomingConnection?(conn)
        }

        lock.withLock { $0.listener = listener }
        listener.start(queue: queue)
    }

    // MARK: - mDNS publish (via dns_sd.h)

    private func advertise(port: UInt16) {
        let txt: [String: String] = [
            "id":   identity.peerID,
            "name": identity.displayName,
            "os":   ClipSync.osIdentifier,
            "v":    String(ClipSync.protocolVersion),
        ]
        publisher.start(
            name: identity.peerID,
            type: ClipSync.serviceType,
            port: port,
            txt: txt,
            queue: queue
        )
    }

    // MARK: - mDNS browse (via dns_sd.h)

    private func startBrowse() {
        browser.onChange = { [weak self] results in
            self?.handle(results: results)
        }
        browser.start(type: ClipSync.serviceType)
    }

    private func handle(results: Set<BonjourBrowser.Result>) {
        var collected: [String: DiscoveredPeer] = [:]

        for r in results {
            // Service instance name == peerID (we set it that way).
            let id = r.txt["id"] ?? r.name
            guard id != identity.peerID else { continue }    // skip self

            let name = r.txt["name"] ?? id
            let os = r.txt["os"] ?? "unknown"
            let v = Int(r.txt["v"] ?? "1") ?? 1

            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(r.host),
                port: NWEndpoint.Port(rawValue: r.port) ?? .any
            )

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
            log.info("peers changed: \(nextPeers.count, privacy: .public) visible")
            let list = Array(nextPeers.values).sorted { $0.displayName < $1.displayName }
            onPeersChanged?(list)
        }
    }

    /// Resolve a `DiscoveredPeer` back to an `NWEndpoint` for `NWConnection`.
    static func endpoint(of peer: DiscoveredPeer) -> NWEndpoint? {
        peer.endpoint.underlying as? NWEndpoint
    }
}
