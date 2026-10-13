//
//  NetworkLinks.swift
//  OpenBeam
//
//  What kind of link each network interface is, so that traffic between two
//  Macs can take the Thunderbolt cable when there is one, and wired Ethernet
//  over Wi-Fi otherwise.
//

import Darwin
import Foundation
import SystemConfiguration

/// The kind of link a network interface is, best first.
enum NetworkLink: String, Comparable {
    case thunderbolt, ethernet, other, wifi

    /// As `screen.offer` carries it; a kind this build does not know ranks as other.
    init(wire: String) { self = NetworkLink(rawValue: wire) ?? .other }

    private var rank: Int {
        switch self {
        case .thunderbolt: return 0
        case .ethernet: return 1
        case .other: return 2
        case .wifi: return 3
        }
    }

    static func < (a: NetworkLink, b: NetworkLink) -> Bool { a.rank < b.rank }
}

enum NetworkLinks {
    /// The link kind of each interface, by BSD name; look up with
    /// `[name, default: .other]`. "Thunderbolt" is a brand, so the localized
    /// names keep it: "Thunderbolt Bridge" (bridge0) and "Thunderbolt 1…" (en1…).
    static func byInterface() -> [String: NetworkLink] {
        var links: [String: NetworkLink] = [:]
        for case let interface as SCNetworkInterface in (SCNetworkInterfaceCopyAll() as NSArray) {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface).map({ $0 as String }) else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(interface).map { $0 as String } ?? ""
            let name = SCNetworkInterfaceGetLocalizedDisplayName(interface).map { $0 as String } ?? ""
            if name.contains("Thunderbolt") {
                links[bsd] = .thunderbolt
            } else if type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                links[bsd] = .wifi
            } else if type == (kSCNetworkInterfaceTypeEthernet as String) {
                links[bsd] = .ethernet
            } else {
                links[bsd] = .other
            }
        }
        return links
    }

    /// This Mac's IPv4 addresses on interfaces that are up and running: the
    /// ones another Mac can reach it at. The Thunderbolt ports that only carry
    /// the bridge have none.
    static func ipv4Interfaces() -> [(name: String, address: String)] {
        var found: [(name: String, address: String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return found }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard let sa = entry.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            let address = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4String($0.pointee.sin_addr) }
            found.append((String(cString: entry.ifa_name), address))
        }
        return found
    }

    /// An address as a string Network.framework dials as is: IPv4 dotted, IPv6
    /// with its interface when link-local ("fe80::1%bridge0"), which pins the
    /// connection to that interface. `interface` names it when the address
    /// itself does not carry its scope.
    static func string(of address: UnsafePointer<sockaddr>, interface fallback: String? = nil) -> String? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4String($0.pointee.sin_addr) }
        case AF_INET6:
            let sin6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            var a = sin6.sin6_addr
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &a, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            let text = String(cString: buffer)
            guard text.hasPrefix("fe80:"), let interface = interfaceName(sin6.sin6_scope_id) ?? fallback else { return text }
            return "\(text)%\(interface)"
        default:
            return nil
        }
    }

    static func interfaceName(_ index: UInt32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        return if_indextoname(index, &buffer).map { String(cString: $0) }
    }
}
