import COpenConnectShim

/// What the server assigned for the tunnel, as libopenconnect reported it.
/// Everything except `gatewayAddress` is server-provided text and has not
/// been validated.
public struct OpenConnectNetworkConfig: Sendable, Equatable {
    /// The VPN server's IP address.
    public var gatewayAddress: String?
    public var address: String?
    /// Dotted quad.
    public var netmask: String?
    public var address6: String?
    /// `address/prefixlen`.
    public var netmask6: String?
    public var dnsServers: [String]
    /// Search domains.
    public var domains: [String]
    public var mtu: Int
    /// Routes as `a.b.c.d/255.255.0.0`, `a.b.c.d/16` or `x:y::/64`.
    public var splitIncludes: [String]
    public var splitExcludes: [String]
    /// Domains to resolve through the tunnel.
    public var splitDNS: [String]

    public init(
        gatewayAddress: String? = nil, address: String? = nil, netmask: String? = nil,
        address6: String? = nil, netmask6: String? = nil, dnsServers: [String] = [],
        domains: [String] = [], mtu: Int = 0, splitIncludes: [String] = [],
        splitExcludes: [String] = [], splitDNS: [String] = []
    ) {
        self.gatewayAddress = gatewayAddress
        self.address = address
        self.netmask = netmask
        self.address6 = address6
        self.netmask6 = netmask6
        self.dnsServers = dnsServers
        self.domains = domains
        self.mtu = mtu
        self.splitIncludes = splitIncludes
        self.splitExcludes = splitExcludes
        self.splitDNS = splitDNS
    }

    init(_ c: ocshim_netconfig) {
        func string(_ p: UnsafePointer<CChar>?) -> String? {
            p.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func list(_ p: UnsafePointer<UnsafePointer<CChar>?>?, _ n: Int32) -> [String] {
            guard let p else { return [] }
            return (0..<Int(n)).compactMap { string(p[$0]) }
        }
        gatewayAddress = string(c.gateway_addr)
        address = string(c.addr)
        netmask = string(c.netmask)
        address6 = string(c.addr6)
        netmask6 = string(c.netmask6)
        dnsServers = [c.dns.0, c.dns.1, c.dns.2].compactMap(string)
        domains = (string(c.domain) ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        mtu = Int(c.mtu)
        splitIncludes = list(c.split_includes, c.n_split_includes)
        splitExcludes = list(c.split_excludes, c.n_split_excludes)
        splitDNS = list(c.split_dns, c.n_split_dns)
    }
}
