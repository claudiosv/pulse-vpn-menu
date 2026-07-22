import Foundation

/// Route table manipulation, mirroring `launcher.py`'s route handling in
/// `connect_once()`/`disconnect()` for macOS's BSD `route(8)` syntax.
struct RouteManager {
    let privileged: PrivilegedRunner

    /// Absolute path — required (not just cleaner) so the sudo-mode NOPASSWD
    /// sudoers rule, which matches an exact resolved path, matches
    /// unambiguously regardless of `sudo`'s own PATH resolution.
    private let routePath = "/sbin/route"

    /// `route change default <gatewayIP>` — macOS BSD syntax omits "gw".
    func setDefaultRoute(gatewayIP: String) async throws {
        try await privileged.run([routePath, "change", "default", gatewayIP])
    }

    /// Looks up any IPv4 address(es) currently cached for `hostname` via the
    /// unprivileged `dscacheutil -q host -a name <hostname>` (no `awk` pipe
    /// needed — parsed directly). Used to clean up a stale VPN-hostname
    /// route left behind after disconnect (`launcher.py:413-427`).
    func resolveViaDSCacheUtil(hostname: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        process.arguments = ["-q", "host", "-a", "name", hostname]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        for line in output.split(separator: "\n") {
            if line.hasPrefix("ip_address:") {
                return line.dropFirst("ip_address:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Full disconnect cleanup: delete the VPN default route (unless
    /// `noDefaultRoute`), delete any stale hostname route, and restore the
    /// original default gateway if it changed. One privileged batch call
    /// (one password dialog), mirroring `launcher.py:387-453`.
    func cleanupAfterDisconnect(
        vpnGatewayIP: String?,
        hostname: String?,
        noDefaultRoute: Bool,
        originalGatewayIP: String?
    ) async throws {
        var commands: [[String]] = []

        if let vpnGatewayIP, !noDefaultRoute {
            commands.append([routePath, "delete", "default", vpnGatewayIP])
        }

        if let hostname, let staleIP = resolveViaDSCacheUtil(hostname: hostname), !staleIP.isEmpty {
            commands.append([routePath, "-n", "delete", staleIP])
        }

        let currentGateway = NetworkInterfaces.defaultGatewayIP()
        if let originalGatewayIP, currentGateway != originalGatewayIP {
            commands.append([routePath, "add", "default", originalGatewayIP])
        }

        guard !commands.isEmpty else { return }
        try await privileged.runBatch(commands)
    }
}
