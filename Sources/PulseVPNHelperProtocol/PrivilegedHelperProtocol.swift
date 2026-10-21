import Foundation

/// Shared between the main app and the privileged helper daemon: constants
/// both sides must agree on, and the XPC protocol itself.
public enum PrivilegedHelperConstants {
    /// Also the launchd `Label`, also the plist filename (minus extension),
    /// also the `MachServices` dictionary key — kept identical everywhere
    /// on purpose, so there's exactly one string to get right.
    public static let machServiceName = "com.claudiosv.pulse-vpn-menu.helper"

    public static let mainAppBundleIdentifier = "com.claudiosv.pulse-vpn-menu"
    public static let teamID = "5HN43G3472"

    /// Required of the CLIENT connecting to the helper's listener — i.e.
    /// "this must be our own signed main app". Matches this app's actual
    /// designated requirement, confirmed via `codesign -d -r-` against the
    /// real built app.
    public static let mainAppRequirement = #"""
    identifier "\#(mainAppBundleIdentifier)" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "\#(teamID)"
    """#

    /// Required of the HELPER the app connects to (mutual auth): same
    /// shape, different identifier.
    public static let helperRequirement = #"""
    identifier "\#(machServiceName)" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "\#(teamID)"
    """#
}

/// Narrowly-typed root operations only — no generic "run this argv as
/// root" passthrough, so a compromised/buggy client can't ask the helper to
/// do anything beyond exactly these operations.
///
/// The VPN session itself runs inside the helper process (libopenconnect,
/// see `OpenConnectKit`) — there is at most one at a time, so there is no
/// session handle to pass around. It survives the app quitting or crashing,
/// just as the old openconnect subprocess did; a relaunched app finds it
/// again through `sessionStatus`.
///
/// Every parameter/reply type here is ObjC-bridgeable (String, [String],
/// Int32, Bool, NSError) — no NSSecureCoding-conforming class needed.
/// Reply-block error parameters must be typed `NSError?`, not `Error?` — a
/// bare `Error` is not a legal type inside an `@objc protocol` and would
/// fail to compile.
@objc public protocol PrivilegedHelperProtocol {
    /// Starts the session on a helper thread and returns as soon as it is
    /// running (errors only if one is already running or the log file can't
    /// be opened). Progress is reported through `logPath` (timestamped
    /// lines) and `sessionStatus`.
    ///
    /// - `vpncScript`: passed to libopenconnect, which runs it as `sh -c`,
    ///   e.g. "vpn-slice 10.0.0.0/8".
    /// - `pinnedCertHash`: a `pin-sha256:...` fingerprint; a server
    ///   certificate that fails normal validation is accepted iff it matches.
    func startSession(
        url: String,
        cookie: String,
        vpncScript: String?,
        pinnedCertHash: String?,
        logPath: String,
        reply: @escaping (NSError?) -> Void
    )

    /// `state`: 0 = no session since the helper started, 1 = running,
    /// 2 = exited (`exitCode` is libopenconnect's result: -EINTR (-4) after
    /// stopSession, -EPERM (-1) for a rejected cookie, ...). The cert fields
    /// are set when the session ended because the server certificate was
    /// rejected; `certHash` is what the user would pin to trust it.
    func sessionStatus(reply: @escaping (
        _ state: Int32,
        _ exitCode: Int32,
        _ startedAt: Double,
        _ certFailureReason: String?,
        _ certHash: String?
    ) -> Void)

    func stopSession(reply: @escaping (NSError?) -> Void)             // ~ SIGTERM
    func requestStatsUpdate(reply: @escaping (NSError?) -> Void)      // ~ SIGUSR1
    func requestReconnect(reply: @escaping (NSError?) -> Void)        // ~ SIGUSR2

    func setDefaultRoute(gatewayIP: String, reply: @escaping (NSError?) -> Void)     // route change default <ip>
    func addDefaultRoute(gatewayIP: String, reply: @escaping (NSError?) -> Void)     // route add default <ip>
    func deleteDefaultRoute(gatewayIP: String, reply: @escaping (NSError?) -> Void)  // route delete default <ip>
    func deleteHostRoute(ip: String, reply: @escaping (NSError?) -> Void)            // route -n delete <ip>
}
