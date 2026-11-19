import Darwin
import Foundation

// Which ways to the paired Mac are worth racing right now, and in what order. Pure apart from
// `NetworkInterface.current()`, so the rules are unit-tested with made-up interfaces.

/// One way to the Mac: an address and how it's dialled.
public struct RemoteCandidate: Hashable, Sendable, Codable {
    public var address: String
    public var route: RemoteRoute

    public init(address: String, route: RemoteRoute) {
        self.address = address
        self.route = route
    }
}

/// One address on one of this device's interfaces (`getifaddrs`).
public struct NetworkInterface: Equatable, Sendable {
    /// "en0", "pdp_ip0", "utun3"…
    public var name: String
    /// Numeric, without a scope ("192.168.8.183", "fd7a:115c:a1e0::5").
    public var address: String
    /// Netmask length (24 for 255.255.255.0); 128/32 for point-to-point.
    public var prefixLength: Int

    public init(name: String, address: String, prefixLength: Int) {
        self.name = name
        self.address = address
        self.prefixLength = prefixLength
    }

    var isIPv4: Bool { RemoteRoutePlan.ipv4(address) != nil }

    /// Whether `ip` (IPv4) is on this interface's subnet.
    func contains(_ ip: UInt32) -> Bool {
        guard let mine = RemoteRoutePlan.ipv4(address), prefixLength > 0, prefixLength <= 32 else { return false }
        let mask: UInt32 = prefixLength == 32 ? .max : ~(UInt32.max >> UInt32(prefixLength))
        return mine & mask == ip & mask
    }

    /// The device's interfaces now (IPv4 and IPv6, with their prefix lengths).
    public static func current() -> [NetworkInterface] {
        var result: [NetworkInterface] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = pointer.pointee.ifa_addr, pointer.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var prefix = family == AF_INET ? 32 : 128
            if let mask = pointer.pointee.ifa_netmask {
                if family == AF_INET {
                    let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                    prefix = bits.nonzeroBitCount
                } else {
                    let bytes = mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                        withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                    }
                    prefix = bytes.reduce(0) { $0 + $1.nonzeroBitCount }
                }
            }
            result.append(NetworkInterface(name: String(cString: pointer.pointee.ifa_name),
                                           address: Tailscale.normalized(String(cString: host)), prefixLength: prefix))
        }
        return result
    }
}

public enum RemoteRoutePlan {
    /// Why a candidate isn't tried (shown in the phone's Connection Log).
    public enum SkipReason: String, Sendable, Equatable {
        /// A private address on a subnet none of this device's interfaces is on (NWError 51).
        case otherNetwork
        /// A tailnet address through the system, with no Tailscale VPN interface up.
        case noTailscaleVPN
        /// The Mac's local-network (Bonjour) name, and the Mac isn't advertising here.
        case notAdvertising
    }

    public struct Plan: Equatable, Sendable {
        /// In launch order: the first starts at once, the rest a moment apart.
        public var candidates: [RemoteCandidate]
        public var skipped: [(candidate: RemoteCandidate, reason: SkipReason)]

        public static func == (lhs: Plan, rhs: Plan) -> Bool {
            lhs.candidates == rhs.candidates
                && lhs.skipped.map(\.candidate) == rhs.skipped.map(\.candidate)
                && lhs.skipped.map(\.reason) == rhs.skipped.map(\.reason)
        }
    }

    /// - Parameters:
    ///   - addresses: in the order they should be tried (`raceOrder`, or the user's).
    ///   - inAppEnabled: the in-app Tailscale node is on: tailnet addresses get it as a second way.
    ///   - remembered: the way that worked last for this Mac: launched first when it's planned.
    ///   - rememberedRoutes: per address, the route to try first among its own (older API).
    ///   - interfaces: this device's interfaces; nil: no filtering (the Mac's own client).
    ///   - advertised: Bonjour names found on this network now; nil: no filtering.
    public static func plan(addresses: [String], inAppEnabled: Bool, remembered: RemoteCandidate? = nil,
                            rememberedRoutes: [String: RemoteRoute] = [:],
                            interfaces: [NetworkInterface]? = nil, advertised: Set<String>? = nil) -> Plan {
        var all: [RemoteCandidate] = []
        for address in addresses {
            for route in InAppTailscale.routes(for: address, inAppEnabled: inAppEnabled, remembered: rememberedRoutes[address]) {
                let candidate = RemoteCandidate(address: address, route: route)
                if !all.contains(candidate) { all.append(candidate) }
            }
        }
        if let remembered, let index = all.firstIndex(of: remembered) {
            all.insert(all.remove(at: index), at: 0)
        }
        var kept: [RemoteCandidate] = []
        var skipped: [(candidate: RemoteCandidate, reason: SkipReason)] = []
        for candidate in all {
            if let reason = skipReason(candidate, interfaces: interfaces, advertised: advertised) {
                skipped.append((candidate, reason))
            } else {
                kept.append(candidate)
            }
        }
        // Nothing left: the detection may be wrong (an interface iOS doesn't list): try them all,
        // as before, rather than never connecting.
        if kept.isEmpty { return Plan(candidates: all, skipped: []) }
        return Plan(candidates: kept, skipped: skipped)
    }

    static func skipReason(_ candidate: RemoteCandidate, interfaces: [NetworkInterface]?, advertised: Set<String>?) -> SkipReason? {
        let address = candidate.address
        if RemoteBonjour.serviceName(of: address) != nil {
            if let advertised, !advertised.contains(address) { return .notAdvertising }
            return nil
        }
        guard let interfaces, candidate.route == .system else { return nil }
        if InAppTailscale.isTailnetAddress(address) {
            return hasTailscaleVPN(interfaces) ? nil : .noTailscaleVPN
        }
        // A private IPv4 literal: reachable only from its own subnet, or through a VPN that may
        // route it (a Tailscale subnet router, a company VPN).
        if let ip = ipv4(address), Tailscale.isPrivateLAN(address), !Tailscale.isLoopback(address) {
            if interfaces.contains(where: { $0.contains(ip) }) { return nil }
            if hasVPN(interfaces) { return nil }
            return .otherNetwork
        }
        return nil
    }

    /// A Tailscale VPN (the Tailscale app's): a utun carrying a 100.64.0.0/10 or
    /// fd7a:115c:a1e0::/48 address. Carrier-grade NAT hands out 100.64/10 too, but on the
    /// cellular interface (pdp_ip*), never on a utun.
    public static func hasTailscaleVPN(_ interfaces: [NetworkInterface]) -> Bool {
        interfaces.contains { $0.name.hasPrefix("utun") && Tailscale.isTailscaleIP($0.address) }
    }

    /// Any VPN with an IPv4 address (iOS keeps a few utuns with only link-local IPv6 for its own
    /// services: those don't count).
    static func hasVPN(_ interfaces: [NetworkInterface]) -> Bool {
        interfaces.contains { ($0.name.hasPrefix("utun") || $0.name.hasPrefix("ipsec") || $0.name.hasPrefix("ppp"))
            && $0.isIPv4 && !$0.address.hasPrefix("169.254.") }
    }

    static func ipv4(_ text: String) -> UInt32? {
        var v4 = in_addr()
        guard inet_pton(AF_INET, text, &v4) == 1 else { return nil }
        return UInt32(bigEndian: v4.s_addr)
    }
}
