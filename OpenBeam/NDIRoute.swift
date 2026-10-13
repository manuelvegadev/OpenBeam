//
//  NDIRoute.swift
//  OpenBeam
//
//  The Thunderbolt address of an NDI source on the other Mac, so that this
//  app's own receivers take the cable.
//
//  A source is advertised by hostname ("macos.local:5962"), and a receiver
//  connecting by name takes whichever of that host's addresses libndi likes
//  best. Between two Apple silicon Macs on a Thunderbolt cable that is often
//  the USB link macOS opens over the same cable (en4/en8, ~340 Mbit/s) rather
//  than the Thunderbolt Bridge (~65 Gbit/s). Given a URL, libndi connects
//  there instead. Receivers outside this app (NDI Virtual Camera, NDI Audio)
//  still choose for themselves.
//

import Darwin
import Foundation
import dnssd
import SystemConfiguration

enum NDIRoute {

    /// "ip:port" of `source` over a Thunderbolt link, or nil when there is no
    /// such link to its host, or the source is this Mac's own. Blocks for up to
    /// a few seconds — a second for mDNS, then discovery for the port — so not
    /// on a queue that is taking frames.
    static func thunderboltURL(for source: String) -> String? {
        guard let host = host(of: source), let address = thunderboltAddress(of: host),
              let port = port(of: source)
        else { return nil }
        return "\(address):\(port)"
    }

    /// "MACOS.LOCAL (macos)" → "macos.local", unless that is this Mac.
    private static func host(of source: String) -> String? {
        guard let open = source.range(of: " (") else { return nil }
        var host = source[..<open.lowerBound].lowercased()
        if !host.contains(".") { host += ".local" }
        let own = (SCDynamicStoreCopyLocalHostName(nil) as String?)?.lowercased()
        return host == own.map({ "\($0).local" }) ? nil : host
    }

    /// The source's port, once discovery reports it.
    private static func port(of source: String) -> String? {
        let finder = NDIFinder()
        finder.start()
        defer { finder.stop() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let url = finder.url(of: source), let colon = url.lastIndex(of: ":") {
                return String(url[url.index(after: colon)...])
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    /// The host's IPv4 address as mDNS answers it on a Thunderbolt interface:
    /// one query over every interface, the first answer that came in over the
    /// cable, or nil after a second.
    private static func thunderboltAddress(of host: String) -> String? {
        let links = NetworkLinks.byInterface()
        let thunderbolt = Set(NetworkLinks.ipv4Interfaces().filter { links[$0.name] == .thunderbolt }.map { if_nametoindex($0.name) })
        guard !thunderbolt.isEmpty else { return nil }

        final class Answer {
            let interfaces: Set<UInt32>
            var address: String?
            init(_ interfaces: Set<UInt32>) { self.interfaces = interfaces }
        }
        let answer = Answer(thunderbolt)
        var ref: DNSServiceRef?
        let callback: DNSServiceGetAddrInfoReply = { _, flags, interface, error, _, address, _, context in
            guard error == kDNSServiceErr_NoError, flags & kDNSServiceFlagsAdd != 0, let address, let context else { return }
            let answer = Unmanaged<Answer>.fromOpaque(context).takeUnretainedValue()
            if answer.address == nil, answer.interfaces.contains(interface) {
                answer.address = NetworkLinks.string(of: address)
            }
        }
        let error = host.withCString {
            DNSServiceGetAddrInfo(&ref, 0, 0, DNSServiceProtocol(kDNSServiceProtocol_IPv4), $0, callback,
                                  Unmanaged.passUnretained(answer).toOpaque())
        }
        guard error == kDNSServiceErr_NoError, let ref else { return nil }
        defer { DNSServiceRefDeallocate(ref) }
        var descriptor = pollfd(fd: DNSServiceRefSockFD(ref), events: Int16(POLLIN), revents: 0)
        let deadline = Date().addingTimeInterval(1)
        while answer.address == nil {
            let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
            guard remaining > 0, poll(&descriptor, 1, remaining) == 1,
                  DNSServiceProcessResult(ref) == kDNSServiceErr_NoError
            else { break }
        }
        return answer.address
    }
}
