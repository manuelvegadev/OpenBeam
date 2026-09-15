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
            let bytes = Array(v.utf8)
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
        ref = sharedRef
        attachDispatchSource(sharedRef, queue: queue)
        log.info("publisher: starting \(name, privacy: .public).\(type, privacy: .public) on port \(port, privacy: .public) (shared conn)")
    }

    func stop() {
        if let src = source {
            // The cancel handler owns the deallocation; see attachDispatchSource.
            src.cancel()
            source = nil
            ref = nil
        } else if let r = ref {
            // No source ever took ownership of the socket.
            DNSServiceRefDeallocate(r)
            ref = nil
        }
    }

    private func attachDispatchSource(_ ref: DNSServiceRef, queue: DispatchQueue) {
        let fd = DNSServiceRefSockFD(ref)
        guard fd >= 0 else {
            DNSServiceRefDeallocate(ref)
            self.ref = nil
            return
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { _ = DNSServiceProcessResult(ref) }
        // DNSServiceRefDeallocate closes the descriptor this source reads, and
        // cancel() is asynchronous: freeing the ref alongside cancel() leaves
        // the source live on a closed — and possibly already reused — fd. The
        // cancel handler is the one point where the source is provably done.
        src.setCancelHandler { DNSServiceRefDeallocate(ref) }
        source = src
        src.resume()
    }

    deinit { stop() }
}

/// One running browser for a given service type. Emits resolved
/// `(name, txt, host, port)` results as peers come/go.
final class BonjourBrowser: @unchecked Sendable {

    struct Result: Hashable {
        let name: String                    // service instance name (== peerID for us)
        let host: String                    // hostname (e.g. "fedora.local.")
        let port: UInt16
        let txt: [String: String]
    }

    /// Called when the resolved set changes. Argument is the *current* set.
    var onChange: ((Set<Result>) -> Void)?

    private var browseRef: DNSServiceRef?
    private var browseSource: DispatchSourceRead?
    private let queue: DispatchQueue

    /// In-flight resolves keyed by service name. Each source's cancel handler
    /// owns its DNSServiceRef, so cancelling is all it takes to tear one down.
    private var resolves: [String: DispatchSourceRead] = [:]
    /// Latest resolved entries keyed by service name.
    private var resolved: [String: Result] = [:]

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
                if (flags & kDNSServiceFlagsAdd) != 0 {
                    me.startResolve(name: n, type: t, domain: d, interfaceIndex: ifaceIdx)
                } else {
                    me.removeResolved(name: n)
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
        browseRef = ref
        let fd = DNSServiceRefSockFD(ref)
        if fd >= 0 {
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { _ = DNSServiceProcessResult(ref) }
            src.setCancelHandler { DNSServiceRefDeallocate(ref) }
            browseSource = src
            src.resume()
        } else {
            DNSServiceRefDeallocate(ref)
            browseRef = nil
        }
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
        for (_, src) in resolves { src.cancel() }
        resolves.removeAll()
        resolved.removeAll()
        onChange?([])
    }

    // MARK: - Resolve

    private func startResolve(name: String, type: String, domain: String, interfaceIndex: UInt32) {
        // If we already have a resolve in flight for this name, leave it.
        if resolves[name] != nil { return }

        var ref: DNSServiceRef?
        let cb: DNSServiceResolveReply = { _, _, _, errCode, fullname, hostTarget, port, txtLen, txtRecord, ctx in
            guard let ctx else { return }
            let me = Unmanaged<BonjourBrowser>.fromOpaque(ctx).takeUnretainedValue()
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
            let result = Result(name: instanceName, host: host, port: portHost, txt: txt)
            me.queue.async { me.upsertResolved(result) }
        }
        let err = name.withCString { namePtr in
            type.withCString { typePtr in
                domain.withCString { domainPtr in
                    DNSServiceResolve(
                        &ref, 0, interfaceIndex,
                        namePtr, typePtr, domainPtr,
                        cb,
                        Unmanaged.passUnretained(self).toOpaque()
                    )
                }
            }
        }
        guard err == kDNSServiceErr_NoError, let ref else {
            log.error("DNSServiceResolve failed: \(err, privacy: .public)")
            return
        }
        let fd = DNSServiceRefSockFD(ref)
        guard fd >= 0 else { DNSServiceRefDeallocate(ref); return }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { _ = DNSServiceProcessResult(ref) }
        src.setCancelHandler { DNSServiceRefDeallocate(ref) }
        resolves[name] = src
        src.resume()
    }

    private func upsertResolved(_ r: Result) {
        let prev = resolved[r.name]
        resolved[r.name] = r
        // Once we have a result, we can tear down the in-flight resolve.
        resolves.removeValue(forKey: r.name)?.cancel()
        if prev != r { onChange?(Set(resolved.values)) }
    }

    private func removeResolved(name: String) {
        resolves.removeValue(forKey: name)?.cancel()
        if resolved.removeValue(forKey: name) != nil {
            onChange?(Set(resolved.values))
        }
    }

    deinit { stop() }
}
