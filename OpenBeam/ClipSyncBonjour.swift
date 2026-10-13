//
//  ClipSyncBonjour.swift
//  OpenBeam
//
//  mDNS service register + browse via the legacy `dns_sd.h` C API.
//
//  We use this instead of Network.framework's NWListener.Service / NWBrowser
//  because the modern Network.framework APIs are gated on macOS 15+ by Local
//  Network permission in a way that doesn't always re-prompt for ad-hoc-signed
//  dev builds (resulting in `-65555: NoAuth` failures even when permission
//  appears to be granted in System Settings). The legacy `dns_sd.h` API runs
//  through `mDNSResponder` directly and isn't subject to that specific gate —
//  this is the same path NDI's SDK uses successfully from the same process.
//

import Foundation
import Network
import dnssd
import os

private let log = Logger(subsystem: "com.openbeam.clipsync", category: "bonjour")

/// A read source that runs `ref`'s callbacks on `queue`, keeping `holding`
/// alive for them, and owns `ref` from here on: cancelling the source frees it.
/// DNSServiceRefDeallocate closes the descriptor the source reads, and cancel()
/// is asynchronous: freeing the ref alongside cancel() leaves the source live on
/// a closed — and possibly already reused — fd. The cancel handler is the one
/// point where the source is provably done. Nil, with `ref` freed, if it has no
/// descriptor.
private func dnsServiceSource(_ ref: DNSServiceRef, queue: DispatchQueue, holding: AnyObject? = nil) -> DispatchSourceRead? {
    let fd = DNSServiceRefSockFD(ref)
    guard fd >= 0 else {
        DNSServiceRefDeallocate(ref)
        return nil
    }
    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    src.setEventHandler {
        _ = holding
        _ = DNSServiceProcessResult(ref)
    }
    src.setCancelHandler { DNSServiceRefDeallocate(ref) }
    src.resume()
    return src
}

/// One advertised service. Hold a reference to keep it published.
final class BonjourPublisher: @unchecked Sendable {

    private var ref: DNSServiceRef?
    private var source: DispatchSourceRead?

    /// Start publishing `name` of `type` on `port`, with the given TXT record.
    /// `txt` keys/values are short UTF-8 strings.
    func start(name: String, type: String, port: UInt16, txt: [String: String], queue: DispatchQueue) {
        stop()

        var txtRef = TXTRecordRef()
        TXTRecordCreate(&txtRef, 0, nil)
        defer { TXTRecordDeallocate(&txtRef) }
        for (k, v) in txt {
            // An entry is one length byte covering "key=value", so the value is
            // cut, on a character boundary, to what fits. A computer name of 64
            // characters can be well over 255 bytes, and UInt8(count) traps.
            let room = max(255 - k.utf8.count - 1, 0)
            var fitted = Substring(v)
            while fitted.utf8.count > room { fitted = fitted.dropLast() }
            let bytes = Array(fitted.utf8)
            _ = bytes.withUnsafeBufferPointer { buf -> DNSServiceErrorType in
                TXTRecordSetValue(&txtRef, k, UInt8(buf.count), buf.baseAddress)
            }
        }
        let txtLen = TXTRecordGetLength(&txtRef)
        let txtBytes = TXTRecordGetBytesPtr(&txtRef)

        // Use a shared DNSServiceRef (DNSServiceCreateConnection) and register
        // the service over it with kDNSServiceFlagsShareConnection. NDI uses
        // this exact pattern and gets through macOS Sequoia's mDNS auth path
        // where standalone DNSServiceRegister calls fail with NoAuth on
        // ad-hoc-signed builds.
        var sharedRef: DNSServiceRef?
        var createErr = DNSServiceCreateConnection(&sharedRef)
        guard createErr == kDNSServiceErr_NoError, let sharedRef else {
            log.error("DNSServiceCreateConnection failed: \(createErr, privacy: .public)")
            return
        }

        var serviceRef: DNSServiceRef? = sharedRef
        let cb: DNSServiceRegisterReply = { _, flags, errCode, name, regtype, domain, ctx in
            let n = name.flatMap { String(cString: $0) } ?? ""
            let t = regtype.flatMap { String(cString: $0) } ?? ""
            let d = domain.flatMap { String(cString: $0) } ?? ""
            if errCode == kDNSServiceErr_NoError {
                log.info("publisher: registered \(n, privacy: .public).\(t, privacy: .public)\(d, privacy: .public)")
            } else {
                log.error("publisher: register callback err=\(errCode, privacy: .public) name=\(n, privacy: .public)")
            }
        }

        let regErr = name.withCString { namePtr -> DNSServiceErrorType in
            type.withCString { typePtr -> DNSServiceErrorType in
                DNSServiceRegister(
                    &serviceRef,
                    DNSServiceFlags(kDNSServiceFlagsShareConnection),
                    0,
                    namePtr,
                    typePtr,
                    nil,
                    nil,
                    UInt16(port).bigEndian,
                    UInt16(txtLen),
                    txtBytes,
                    cb,
                    nil
                )
            }
        }

        if regErr != kDNSServiceErr_NoError {
            log.error("DNSServiceRegister (shared) failed: \(regErr, privacy: .public)")
            DNSServiceRefDeallocate(sharedRef)
            return
        }
        // Hold onto the shared ref (it owns the socket); the per-service ref
        // was incremented by Register and is freed when we deallocate the shared one.
        source = dnsServiceSource(sharedRef, queue: queue)
        ref = source == nil ? nil : sharedRef
        log.info("publisher: starting \(name, privacy: .public).\(type, privacy: .public) on port \(port, privacy: .public) (shared conn)")
    }

    func stop() {
        if let src = source {
            // The cancel handler owns the deallocation; see dnsServiceSource.
            src.cancel()
            source = nil
            ref = nil
        } else if let r = ref {
            // No source ever took ownership of the socket.
            DNSServiceRefDeallocate(r)
            ref = nil
        }
    }

    deinit { stop() }
}

/// One running browser for a given service type. Emits resolved
/// `(name, txt, host, port)` results as peers come/go — one per interface a
/// peer is seen on, with its addresses there, so a caller can pick the link.
final class BonjourBrowser: @unchecked Sendable {

    struct Result: Hashable {
        let name: String                    // service instance name (== peerID for us)
        let host: String                    // hostname (e.g. "fedora.local.")
        let port: UInt16
        let txt: [String: String]
        /// The interface it was seen on, by BSD name ("bridge0", "en0").
        let interface: String
        /// The host's addresses on that interface, as `NetworkLinks.string(of:)`
        /// writes them; empty until looked up.
        var addresses: [String] = []
    }

    /// Called when the resolved set changes. Argument is the *current* set.
    var onChange: ((Set<Result>) -> Void)?

    private var browseRef: DNSServiceRef?
    private var browseSource: DispatchSourceRead?
    private let queue: DispatchQueue

    private struct Key: Hashable {
        let name: String
        let interfaceIndex: UInt32
    }

    /// One service on one interface: its resolve, which stays open, and the
    /// address lookup for the host that resolve named. Each source's cancel
    /// handler owns its DNSServiceRef, so cancelling is all it takes to tear
    /// one down; the sources hold the entry their callbacks are handed.
    private final class Entry {
        let key: Key
        let interface: String
        weak var browser: BonjourBrowser?
        var resolve: DispatchSourceRead?
        var lookup: DispatchSourceRead?
        var result: Result?
        var addresses = Set<String>()

        init(key: Key, browser: BonjourBrowser) {
            self.key = key
            self.browser = browser
            interface = NetworkLinks.interfaceName(key.interfaceIndex) ?? ""
        }

        func cancel() {
            resolve?.cancel()
            lookup?.cancel()
            resolve = nil
            lookup = nil
        }
    }

    private var entries: [Key: Entry] = [:]
    private var published = Set<Result>()

    init(queue: DispatchQueue) { self.queue = queue }

    func start(type: String) {
        stop()
        var ref: DNSServiceRef?
        let err = type.withCString { typePtr -> DNSServiceErrorType in
            let cb: DNSServiceBrowseReply = { _, flags, ifaceIdx, errCode, name, regtype, replyDomain, ctx in
                guard let ctx else { return }
                let me = Unmanaged<BonjourBrowser>.fromOpaque(ctx).takeUnretainedValue()
                guard errCode == kDNSServiceErr_NoError else {
                    log.error("browse callback err: \(errCode, privacy: .public)")
                    return
                }
                let n = name.flatMap { String(cString: $0) } ?? ""
                let t = regtype.flatMap { String(cString: $0) } ?? ""
                let d = replyDomain.flatMap { String(cString: $0) } ?? ""
                let key = Key(name: n, interfaceIndex: ifaceIdx)
                if (flags & kDNSServiceFlagsAdd) != 0 {
                    me.startResolve(key, type: t, domain: d)
                } else {
                    me.remove(key)
                }
            }
            return DNSServiceBrowse(
                &ref, 0, 0, typePtr, nil, cb,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        guard err == kDNSServiceErr_NoError, let ref else {
            log.error("DNSServiceBrowse failed: \(err, privacy: .public)")
            return
        }
        browseSource = dnsServiceSource(ref, queue: queue)
        browseRef = browseSource == nil ? nil : ref
        log.info("browser: started for \(type, privacy: .public)")
    }

    func stop() {
        if let src = browseSource {
            src.cancel()
            browseSource = nil
            browseRef = nil
        } else if let r = browseRef {
            DNSServiceRefDeallocate(r)
            browseRef = nil
        }
        for entry in entries.values { entry.cancel() }
        entries.removeAll()
        published.removeAll()
        onChange?([])
    }

    // MARK: - Resolve

    private func startResolve(_ key: Key, type: String, domain: String) {
        // If we already have a resolve in flight for this name here, leave it.
        if entries[key] != nil { return }
        let entry = Entry(key: key, browser: self)

        var ref: DNSServiceRef?
        let cb: DNSServiceResolveReply = { _, _, _, errCode, fullname, hostTarget, port, txtLen, txtRecord, ctx in
            guard let ctx else { return }
            let entry = Unmanaged<Entry>.fromOpaque(ctx).takeUnretainedValue()
            guard errCode == kDNSServiceErr_NoError else {
                log.error("resolve callback err: \(errCode, privacy: .public)")
                return
            }
            let full = fullname.flatMap { String(cString: $0) } ?? ""
            let host = hostTarget.flatMap { String(cString: $0) } ?? ""
            let portHost = UInt16(bigEndian: port)
            // Parse TXT into [String: String].
            var txt: [String: String] = [:]
            if let txtRecord {
                let count = TXTRecordGetCount(txtLen, txtRecord)
                for i in 0..<count {
                    var key = [CChar](repeating: 0, count: 256)
                    var valueLen: UInt8 = 0
                    var valuePtr: UnsafeRawPointer?
                    let rc = key.withUnsafeMutableBufferPointer { keyBuf -> DNSServiceErrorType in
                        TXTRecordGetItemAtIndex(txtLen, txtRecord, i, UInt16(keyBuf.count), keyBuf.baseAddress, &valueLen, &valuePtr)
                    }
                    guard rc == kDNSServiceErr_NoError else { continue }
                    let k = String(cString: key)
                    let v: String
                    if let vp = valuePtr, valueLen > 0 {
                        let buf = UnsafeBufferPointer(start: vp.assumingMemoryBound(to: UInt8.self), count: Int(valueLen))
                        v = String(decoding: buf, as: UTF8.self)
                    } else {
                        v = ""
                    }
                    txt[k] = v
                }
            }

            // Service instance name is the leftmost label of `full`. dns_sd
            // gives us the full triplet; we want just the instance name.
            let instanceName = full.split(separator: ".").first.map(String.init) ?? full
            let result = Result(name: instanceName, host: host, port: portHost, txt: txt, interface: entry.interface)
            entry.browser?.resolved(result, for: entry)
        }
        let err = key.name.withCString { namePtr in
            type.withCString { typePtr in
                domain.withCString { domainPtr in
                    DNSServiceResolve(
                        &ref, 0, key.interfaceIndex,
                        namePtr, typePtr, domainPtr,
                        cb,
                        Unmanaged.passUnretained(entry).toOpaque()
                    )
                }
            }
        }
        guard err == kDNSServiceErr_NoError, let ref else {
            log.error("DNSServiceResolve failed: \(err, privacy: .public)")
            return
        }
        guard let src = dnsServiceSource(ref, queue: queue, holding: entry) else { return }
        entry.resolve = src
        entries[key] = entry
    }

    private func resolved(_ r: Result, for entry: Entry) {
        // The resolve stays open for as long as the service is there. A peer that
        // restarts comes back under the same name on a new port, and the browse
        // does not always report that as a remove and an add; only a live resolve
        // hears the new port. Tearing it down after the first answer left us
        // dialling the old port until this app restarted.
        let hostChanged = entry.result?.host != r.host
        entry.result = r
        if hostChanged { lookUpAddresses(of: r.host, for: entry) }
        publish()
    }

    // MARK: - Addresses

    /// The host's addresses on the entry's interface only, followed for as long
    /// as the entry lives: a link-local address changes when the peer restarts.
    private func lookUpAddresses(of host: String, for entry: Entry) {
        entry.lookup?.cancel()
        entry.lookup = nil
        entry.addresses.removeAll()

        var ref: DNSServiceRef?
        let cb: DNSServiceGetAddrInfoReply = { _, flags, _, errCode, _, address, _, ctx in
            guard let ctx, errCode == kDNSServiceErr_NoError, let address else { return }
            let entry = Unmanaged<Entry>.fromOpaque(ctx).takeUnretainedValue()
            guard let text = NetworkLinks.string(of: address, interface: entry.interface) else { return }
            if (flags & kDNSServiceFlagsAdd) != 0 {
                entry.addresses.insert(text)
            } else {
                entry.addresses.remove(text)
            }
            // A host's addresses come in a burst; the set is passed on once it is in.
            if (flags & kDNSServiceFlagsMoreComing) == 0 { entry.browser?.publish() }
        }
        let err = host.withCString { hostPtr in
            DNSServiceGetAddrInfo(&ref, 0, entry.key.interfaceIndex,
                                  DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6),
                                  hostPtr, cb, Unmanaged.passUnretained(entry).toOpaque())
        }
        guard err == kDNSServiceErr_NoError, let ref else {
            log.error("DNSServiceGetAddrInfo failed: \(err, privacy: .public)")
            return
        }
        entry.lookup = dnsServiceSource(ref, queue: queue, holding: entry)
    }

    private func remove(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.cancel()
        publish()
    }

    private func publish() {
        let current = Set(entries.values.compactMap { entry -> Result? in
            guard var r = entry.result else { return nil }
            r.addresses = entry.addresses.sorted()
            return r
        })
        guard current != published else { return }
        published = current
        onChange?(current)
    }

    deinit { stop() }
}
