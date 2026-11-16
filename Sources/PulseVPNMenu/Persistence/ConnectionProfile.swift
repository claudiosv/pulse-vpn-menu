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
        self.post = post
        self.noDefaultRoute = noDefaultRoute
        self.debug = debug
        self.lastDSID = lastDSID
        self.pinnedCertHash = pinnedCertHash
    }

    /// `splitRoutes` as separate entries.
    var splitRouteList: [String] {
        (splitRoutes ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
    }

    /// What the packet tunnel provider needs to run this connection. The
    /// login cookie is deliberately not part of it.
    var tunnelConfiguration: TunnelConfiguration {
        TunnelConfiguration(
            profileID: id,
            vpnURL: vpnURL,
            pinnedCertHash: pinnedCertHash,
            verbose: debug,
            routing: RoutingOptions(splitRoutes: splitRouteList, forceDefaultRoute: !noDefaultRoute)
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
