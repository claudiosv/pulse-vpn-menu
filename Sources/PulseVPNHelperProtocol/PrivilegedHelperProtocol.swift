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
/// root" passthrough, and no signal number ever crosses this boundary
/// (three dedicated signal methods instead), so a compromised/buggy client
/// can't ask the helper to do anything beyond exactly these operations.
///
/// Every parameter/reply type here is ObjC-bridgeable (String, [String],
/// Int32, Bool, NSError) — no NSSecureCoding-conforming class needed.
/// Reply-block error parameters must be typed `NSError?`, not `Error?` — a
/// bare `Error` is not a legal type inside an `@objc protocol` and would
/// fail to compile.
@objc public protocol PrivilegedHelperProtocol {
    /// Spawns openconnect directly as root (the helper already runs as
    /// root via launchd — no sudo, no shell involved at all). `argv[0]` is
    /// the resolved openconnect path, `argv[1...]` its arguments. Redirects
    /// stdout+stderr to `logPath`. Replies with the REAL pid synchronously:
    /// `Process.processIdentifier` from the helper's own spawn, since
    /// there's no intermediate `sudo` to fork through anymore (unlike the
    /// sudoers-based design this replaces, which had to walk `ps`'s process
    /// tree to find openconnect's real pid underneath `sudo`'s).
    func launchOpenConnect(argv: [String], logPath: String, reply: @escaping (Int32, NSError?) -> Void)

    /// 3-state, not 2: `known` distinguishes "this helper instance spawned
    /// and is still tracking this pid" from "helper doesn't recognize this
    /// pid" (e.g. after a helper crash/relaunch mid-connection).
    /// `running`/`exitCode` are only meaningful when `known == true`.
    func processStatus(pid: Int32, reply: @escaping (_ known: Bool, _ running: Bool, _ exitCode: Int32) -> Void)

    func terminateOpenConnect(pid: Int32, reply: @escaping (NSError?) -> Void)   // SIGTERM
    func requestStatsUpdate(pid: Int32, reply: @escaping (NSError?) -> Void)     // SIGUSR1
    func requestReconnect(pid: Int32, reply: @escaping (NSError?) -> Void)       // SIGUSR2

    func setDefaultRoute(gatewayIP: String, reply: @escaping (NSError?) -> Void)     // route change default <ip>
    func addDefaultRoute(gatewayIP: String, reply: @escaping (NSError?) -> Void)     // route add default <ip>
    func deleteDefaultRoute(gatewayIP: String, reply: @escaping (NSError?) -> Void)  // route delete default <ip>
    func deleteHostRoute(ip: String, reply: @escaping (NSError?) -> Void)            // route -n delete <ip>
}
