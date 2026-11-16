import Darwin
import Foundation
import NetworkExtension
import OpenConnectKit
import PulseVPNTunnelProtocol

/// The addresses, routes and DNS for one tunnel, worked out from what the
/// server assigned and the connection's routing options. This is the job the
/// vpnc-script used to do; here it becomes `NEPacketTunnelNetworkSettings`,
/// which the system applies (and removes again when the tunnel ends).
///
/// A plain value so the decisions can be tested without a provider.
public struct TunnelPlan: Equatable, Sendable {
    public struct Route4: Equatable, Hashable, Sendable {
        public var address: String
        public var mask: String
        public static let `default` = Route4(address: "0.0.0.0", mask: "0.0.0.0")
    }

    public struct Route6: Equatable, Hashable, Sendable {
        public var address: String
        public var prefixLength: Int
        public static let `default` = Route6(address: "::", prefixLength: 0)
    }

    public struct IPv4: Equatable, Sendable {
        public var address: String
        public var mask: String
        public var included: [Route4]
        public var excluded: [Route4]
    }

    public struct IPv6: Equatable, Sendable {
        public var address: String
        public var prefixLength: Int
        public var included: [Route6]
        public var excluded: [Route6]
    }

    /// The VPN server's address (informational: shown by the system).
    public var remoteAddress: String
    public var ipv4: IPv4?
    public var ipv6: IPv6?
    public var dnsServers: [String]
    public var searchDomains: [String]
    /// Domains resolved through the tunnel's DNS servers. Nil means the
    /// tunnel's DNS is the default resolver whenever the tunnel carries the
    /// default route (and is otherwise unused).
    public var matchDomains: [String]?
    public var mtu: Int?
    /// Everything goes through the tunnel.
    public var isFullTunnel: Bool

    public enum PlanError: Error, LocalizedError, Equatable {
        case noUsableAddress

        public var errorDescription: String? {
            "The server did not assign a usable tunnel address."
        }
    }

    /// - Routes: `routing.splitRoutes` if given; otherwise everything when
    ///   `routing.forceDefaultRoute` is set or the server asks for no
    ///   particular routes; otherwise the server's split-include routes.
    ///   The server's split-exclude routes are always honoured.
    /// - DNS: the server's resolvers. For a full tunnel they become the
    ///   default; for a split tunnel they answer only for the server's
    ///   split-DNS domains (or, without any, its search domains), and are
    ///   themselves routed through the tunnel.
    public static func make(
        server: OpenConnectNetworkConfig,
        routing: RoutingOptions,
        fallbackRemoteAddress: String
    ) throws -> TunnelPlan {
        let userRoutes = routing.splitRoutes.map { $0.trimmingCharacters(in: .whitespaces) }
        let user4 = userRoutes.compactMap(parseRoute4)
        let user6 = userRoutes.compactMap(parseRoute6)
        let server4 = server.splitIncludes.compactMap(parseRoute4)
        let server6 = server.splitIncludes.compactMap(parseRoute6)

        let useUserRoutes = !(user4.isEmpty && user6.isEmpty)
        let fullTunnel = !useUserRoutes
            && (routing.forceDefaultRoute || (server4.isEmpty && server6.isEmpty))

        let dns = server.dnsServers.filter { isIPv4($0) || isIPv6($0) }

        var ipv4: IPv4?
        if let address = server.address, isIPv4(address) {
            let mask = server.netmask.flatMap { isIPv4($0) ? $0 : nil } ?? "255.255.255.255"
            var included: [Route4]
            if fullTunnel {
                included = [.default]
            } else {
                included = useUserRoutes ? user4 : server4
                // The tunnel's own subnet, as the vpnc-script routed it.
                if mask != "255.255.255.255", let subnet = parseRoute4("\(address)/\(mask)") {
                    included.append(subnet)
                }
                included += dns.filter(isIPv4).map { Route4(address: $0, mask: "255.255.255.255") }
            }
            ipv4 = IPv4(
                address: address, mask: mask,
                included: unique(included),
                excluded: unique(server.splitExcludes.compactMap(parseRoute4))
            )
        }

        var ipv6: IPv6?
        if let (address, prefix) = ipv6Address(server) {
            var included: [Route6]
            if fullTunnel {
                included = [.default]
            } else {
                included = useUserRoutes ? user6 : server6
                included += dns.filter(isIPv6).map { Route6(address: $0, prefixLength: 128) }
            }
            ipv6 = IPv6(
                address: address, prefixLength: prefix,
                included: unique(included),
                excluded: unique(server.splitExcludes.compactMap(parseRoute6))
            )
        }

        guard ipv4 != nil || ipv6 != nil else { throw PlanError.noUsableAddress }

        var matchDomains: [String]?
        if !fullTunnel {
            let domains = server.splitDNS.isEmpty ? server.domains : server.splitDNS
            matchDomains = domains.isEmpty ? nil : domains
        }

        return TunnelPlan(
            remoteAddress: server.gatewayAddress ?? fallbackRemoteAddress,
            ipv4: ipv4,
            ipv6: ipv6,
            dnsServers: dns,
            searchDomains: server.domains,
            matchDomains: matchDomains,
            mtu: (576...9000).contains(server.mtu) ? server.mtu : nil,
            isFullTunnel: fullTunnel
        )
    }

    /// The settings to hand to `setTunnelNetworkSettings`.
    public func networkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)

        if let ipv4 {
            let v4 = NEIPv4Settings(addresses: [ipv4.address], subnetMasks: [ipv4.mask])
            v4.includedRoutes = ipv4.included.map(Self.neRoute)
            v4.excludedRoutes = ipv4.excluded.map(Self.neRoute)
            settings.ipv4Settings = v4
        }
        if let ipv6 {
            let v6 = NEIPv6Settings(
                addresses: [ipv6.address],
                networkPrefixLengths: [NSNumber(value: ipv6.prefixLength)]
            )
            v6.includedRoutes = ipv6.included.map(Self.neRoute)
            v6.excludedRoutes = ipv6.excluded.map(Self.neRoute)
            settings.ipv6Settings = v6
        }
        if !dnsServers.isEmpty {
            let dns = NEDNSSettings(servers: dnsServers)
            dns.searchDomains = searchDomains.isEmpty ? nil : searchDomains
            dns.matchDomains = matchDomains
            settings.dnsSettings = dns
        }
        if let mtu {
            settings.mtu = NSNumber(value: mtu)
        }
        return settings
    }

    private static func neRoute(_ route: Route4) -> NEIPv4Route {
        route == .default
            ? .default()
            : NEIPv4Route(destinationAddress: route.address, subnetMask: route.mask)
    }

    private static func neRoute(_ route: Route6) -> NEIPv6Route {
        route == .default
            ? .default()
            : NEIPv6Route(
                destinationAddress: route.address,
                networkPrefixLength: NSNumber(value: route.prefixLength)
            )
    }

    // MARK: - Parsing (server-provided text: anything malformed is dropped)

    /// `a.b.c.d`, `a.b.c.d/n` or `a.b.c.d/m.m.m.m`, normalised to its network
    /// address. Nil for anything else, including IPv6.
    static func parseRoute4(_ text: String) -> Route4? {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let address = ipv4Bits(parts[0]) else { return nil }
        var mask: UInt32 = 0xFFFF_FFFF
        if parts.count == 2 {
            if let length = Int(parts[1]) {
                guard (0...32).contains(length) else { return nil }
                mask = length == 0 ? 0 : ~UInt32(0) << UInt32(32 - length)
            } else if let bits = ipv4Bits(parts[1]) {
                mask = bits
            } else {
                return nil
            }
        }
        return Route4(address: ipv4Text(address & mask), mask: ipv4Text(mask))
    }

    /// `x:y::z` or `x:y::/n`. Nil for anything else, including IPv4.
    static func parseRoute6(_ text: String) -> Route6? {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard isIPv6(parts[0]) else { return nil }
        var length = 128
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), (0...128).contains(parsed) else { return nil }
            length = parsed
        }
        return Route6(address: parts[0], prefixLength: length)
    }

    /// libopenconnect gives IPv6 as `addr6` (a bare address) and/or
    /// `netmask6` (`address/prefixlen`).
    private static func ipv6Address(_ server: OpenConnectNetworkConfig) -> (String, Int)? {
        if let combined = server.netmask6, let route = parseRoute6(combined) {
            return (server.address6.flatMap { isIPv6($0) ? $0 : nil } ?? route.address, route.prefixLength)
        }
        if let address = server.address6, isIPv6(address) {
            return (address, 128)
        }
        return nil
    }

    static func isIPv4(_ text: String) -> Bool { ipv4Bits(text) != nil }

    static func isIPv6(_ text: String) -> Bool {
        var address = in6_addr()
        return inet_pton(AF_INET6, text, &address) == 1
    }

    /// Host byte order.
    private static func ipv4Bits(_ text: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func ipv4Text(_ bits: UInt32) -> String {
        "\(bits >> 24).\((bits >> 16) & 0xFF).\((bits >> 8) & 0xFF).\(bits & 0xFF)"
    }

    private static func unique<T: Hashable>(_ items: [T]) -> [T] {
        var seen = Set<T>()
        return items.filter { seen.insert($0).inserted }
    }
}
