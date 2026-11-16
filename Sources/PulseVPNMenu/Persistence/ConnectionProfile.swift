import Foundation
import PulseVPNTunnelProtocol

/// A single named VPN connection configuration. Replaces the Python app's
/// single-profile `config.toml` with a multi-profile JSON model. Each one is
/// also saved as a VPN configuration (see `TunnelClient`), which is what
/// makes it show up in System Settings > VPN.
struct ConnectionProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var vpnURL: String
    /// Destinations to send through the tunnel instead of whatever the
    /// server asks for: IPv4/IPv6 addresses or CIDR ranges separated by
    /// commas or spaces, e.g. "169.237.0.0/16, 10.1.2.3". Empty means the
    /// routes are decided by `noDefaultRoute` and the server.
    var splitRoutes: String?
    /// DNS servers to use instead of the ones the VPN server provides, in
    /// the same list format. Empty means the server's.
    var dnsServers: String?
    /// The only domains to look up through the VPN's DNS, in the same list
    /// format. Empty leaves that to the routes and the server.
    var dnsDomains: String?
    /// Command to run once the tunnel is up.
    var post: String?
    /// Don't force everything through the tunnel: use the server's own
    /// split routes if it sends any.
    var noDefaultRoute: Bool
    /// Debug-level libopenconnect logging for this connection's session.
    var debug: Bool
    /// Cached DSID cookie so re-connecting doesn't always require a fresh
    /// browser login. Cleared whenever openconnect rejects it (-EPERM).
    var lastDSID: String?
    /// `pin-sha256:...` of a server certificate the user chose to trust even
    /// though it fails normal validation (self-signed, private CA). A
    /// different certificate is rejected again and prompts anew.
    var pinnedCertHash: String?

    init(
        id: UUID = UUID(),
        name: String,
        vpnURL: String,
        splitRoutes: String? = nil,
        dnsServers: String? = nil,
        dnsDomains: String? = nil,
        post: String? = nil,
        noDefaultRoute: Bool = false,
        debug: Bool = false,
        lastDSID: String? = nil,
        pinnedCertHash: String? = nil
    ) {
        self.id = id
        self.name = name
        self.vpnURL = vpnURL
        self.splitRoutes = splitRoutes
        self.dnsServers = dnsServers
        self.dnsDomains = dnsDomains
        self.post = post
        self.noDefaultRoute = noDefaultRoute
        self.debug = debug
        self.lastDSID = lastDSID
        self.pinnedCertHash = pinnedCertHash
    }

    /// `splitRoutes` as separate entries.
    var splitRouteList: [String] { Self.entries(splitRoutes) }
    var dnsServerList: [String] { Self.entries(dnsServers) }
    var dnsDomainList: [String] { Self.entries(dnsDomains) }

    /// A stored list (entries separated by commas or whitespace) taken apart.
    private static func entries(_ list: String?) -> [String] {
        (list ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
    }

    /// An IPv4 or IPv6 address.
    static func isValidAddress(_ text: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    /// A DNS domain name: dot-separated labels of letters, digits and
    /// hyphens, at least two of them, not an IP address. A leading `*.` is
    /// allowed: `*.example.edu` means the same as `example.edu`, since a
    /// domain always covers its subdomains (see `TunnelPlan`).
    static func isValidDomain(_ text: String) -> Bool {
        let text = text.hasPrefix("*.") ? String(text.dropFirst(2)) : text
        guard text.count <= 253, !isValidAddress(text) else { return false }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            (1...63).contains(label.count)
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                && label.first != "-" && label.last != "-"
        }
    }

    /// Whether `text` can be a split route: an IPv4 or IPv6 address,
    /// optionally followed by `/` and a prefix length in range.
    static func isValidRoute(_ text: String) -> Bool {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var v4 = in_addr(), v6 = in6_addr()
        let maxPrefix: Int
        if inet_pton(AF_INET, parts[0], &v4) == 1 {
            maxPrefix = 32
        } else if inet_pton(AF_INET6, parts[0], &v6) == 1 {
            maxPrefix = 128
        } else {
            return false
        }
        guard parts.count == 2 else { return true }
        guard let prefix = Int(parts[1]), parts[1].allSatisfy(\.isNumber) else { return false }
        return (0...maxPrefix).contains(prefix)
    }

    /// What the packet tunnel provider needs to run this connection. The
    /// login cookie is deliberately not part of it.
    var tunnelConfiguration: TunnelConfiguration {
        TunnelConfiguration(
            profileID: id,
            vpnURL: vpnURL,
            pinnedCertHash: pinnedCertHash,
            verbose: debug,
            routing: RoutingOptions(splitRoutes: splitRouteList, forceDefaultRoute: !noDefaultRoute),
            dns: DNSOptions(servers: dnsServerList, domains: dnsDomainList)
        )
    }

    // MARK: - Decoding (with migration from the vpnc-script era)

    /// Profiles saved before the Network Extension port had a `script` (run
    /// by libopenconnect as root) instead of `splitRoutes`.
    private enum LegacyKeys: String, CodingKey {
        case script
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        vpnURL = try values.decode(String.self, forKey: .vpnURL)
        dnsServers = try values.decodeIfPresent(String.self, forKey: .dnsServers)
        dnsDomains = try values.decodeIfPresent(String.self, forKey: .dnsDomains)
        post = try values.decodeIfPresent(String.self, forKey: .post)
        noDefaultRoute = try values.decodeIfPresent(Bool.self, forKey: .noDefaultRoute) ?? false
        debug = try values.decodeIfPresent(Bool.self, forKey: .debug) ?? false
        lastDSID = try values.decodeIfPresent(String.self, forKey: .lastDSID)
        pinnedCertHash = try values.decodeIfPresent(String.self, forKey: .pinnedCertHash)
        if let routes = try values.decodeIfPresent(String.self, forKey: .splitRoutes) {
            splitRoutes = routes
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            splitRoutes = Self.routes(fromLegacyScript: try legacy.decodeIfPresent(String.self, forKey: .script))
        }
    }

    /// The address and CIDR arguments of a `vpn-slice ...` command line, the
    /// one kind of script that maps onto routes. Host names (which vpn-slice
    /// resolved and routed one by one) and any other script are dropped.
    static func routes(fromLegacyScript script: String?) -> String? {
        guard let script else { return nil }
        let words = script.split(separator: " ").map(String.init)
        guard let command = words.first, command.hasSuffix("vpn-slice") else { return nil }
        let routes = words.dropFirst().filter { word in
            let address = word.split(separator: "/").first.map(String.init) ?? ""
            var v4 = in_addr(), v6 = in6_addr()
            return inet_pton(AF_INET, address, &v4) == 1 || inet_pton(AF_INET6, address, &v6) == 1
        }
        return routes.isEmpty ? nil : routes.joined(separator: ", ")
    }
}
