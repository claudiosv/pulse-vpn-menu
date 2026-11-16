import Foundation

/// Shared between the app and its packet tunnel system extension: the
/// identifiers and wire constants both sides must agree on.
public enum TunnelConstants {
    public static let teamID = "5HN43G3472"
    public static let appBundleIdentifier = "ai.claudio.openconnect"

    /// The system extension's bundle identifier, and the
    /// `providerBundleIdentifier` of every VPN configuration the app saves.
    /// Must match `TUNNEL_BUNDLE_ID` in build.sh.
    public static let extensionBundleIdentifier = "ai.claudio.openconnect.networkextension"

    /// Bump whenever `TunnelRequest`, `TunnelReply`, `TunnelConfiguration` or
    /// the start options change incompatibly. Every reply carries it.
    public static let protocolVersion = 3

    /// Domain of the errors the provider ends a tunnel with. The code is the
    /// positive errno of libopenconnect's result (see `SessionStatus.exitCode`).
    public static let errorDomain = "ai.claudio.openconnect.networkextension"

    /// Darwin notification the provider posts whenever the `SessionStatus` it
    /// would report has changed (not for counters). It carries no payload:
    /// the app answers by polling.
    public static let statusChangedNotification = "ai.claudio.openconnect.networkextension.status-changed"

    /// `SessionStatus.exitCode` when the tunnel was started without a login
    /// cookie, i.e. from System Settings rather than by the app. The app
    /// reacts by running its browser login and starting the tunnel itself.
    public static let needsLoginExitCode: Int32 = -EAUTH

    /// Key in `NETunnelProviderProtocol.providerConfiguration` holding a
    /// JSON-encoded `TunnelConfiguration`.
    public static let configurationKey = "configuration"

    /// Key in the `startVPNTunnel(options:)` dictionary holding the DSID
    /// login cookie. It is only ever passed this way, never saved in the
    /// VPN configuration.
    public static let cookieOptionKey = "cookie"
}

/// How the tunnel's routes are chosen; see `TunnelPlan`.
public struct RoutingOptions: Codable, Sendable, Equatable {
    /// Send only these destinations (`a.b.c.d/n`, `a.b.c.d`, `x:y::/n`)
    /// through the tunnel, ignoring the routes the server asks for.
    public var splitRoutes: [String]
    /// With no `splitRoutes`: send everything through the tunnel even if the
    /// server only asks for some routes.
    public var forceDefaultRoute: Bool

    public init(splitRoutes: [String] = [], forceDefaultRoute: Bool = true) {
        self.splitRoutes = splitRoutes
        self.forceDefaultRoute = forceDefaultRoute
    }
}

/// One connection's settings as the provider needs them. Saved (as JSON) in
/// the VPN configuration that shows up in System Settings > VPN, so the
/// provider has it however the tunnel was started.
public struct TunnelConfiguration: Codable, Sendable, Equatable {
    /// The `ConnectionProfile` this configuration belongs to.
    public var profileID: UUID
    public var vpnURL: String
    /// A `pin-sha256:...` fingerprint; a server certificate that fails normal
    /// validation is accepted iff it matches.
    public var pinnedCertHash: String?
    /// libopenconnect debug-level logging.
    public var verbose: Bool
    public var routing: RoutingOptions

    public init(
        profileID: UUID, vpnURL: String, pinnedCertHash: String? = nil,
        verbose: Bool = false, routing: RoutingOptions = RoutingOptions()
    ) {
        self.profileID = profileID
        self.vpnURL = vpnURL
        self.pinnedCertHash = pinnedCertHash
        self.verbose = verbose
        self.routing = routing
    }

    /// The value for `NETunnelProviderProtocol.providerConfiguration`.
    public func providerConfiguration() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [TunnelConstants.configurationKey: data]
    }

    public init?(providerConfiguration: [String: Any]?) {
        guard let data = providerConfiguration?[TunnelConstants.configurationKey] as? Data,
              let decoded = try? JSONDecoder().decode(TunnelConfiguration.self, from: data)
        else { return nil }
        self = decoded
    }
}
