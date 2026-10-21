import Foundation

/// A single named VPN connection configuration. Replaces the Python app's
/// single-profile `config.toml` with a multi-profile JSON model.
struct ConnectionProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var vpnURL: String
    /// vpnc-compatible script run by libopenconnect (like `openconnect -s`), e.g. "vpn-slice 169.237.0.0/16".
    var script: String?
    /// Command to run once the tunnel is up.
    var post: String?
    var noDefaultRoute: Bool
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
        script: String? = nil,
        post: String? = nil,
        noDefaultRoute: Bool = false,
        debug: Bool = false,
        lastDSID: String? = nil,
        pinnedCertHash: String? = nil
    ) {
        self.id = id
        self.name = name
        self.vpnURL = vpnURL
        self.script = script
        self.post = post
        self.noDefaultRoute = noDefaultRoute
        self.debug = debug
        self.lastDSID = lastDSID
        self.pinnedCertHash = pinnedCertHash
    }
}
