import Foundation

/// Route table manipulation, mirroring `launcher.py`'s route handling in
/// `connect_once()`/`disconnect()` for macOS's BSD `route(8)` syntax. Talks
/// to the privileged helper daemon (`PrivilegedHelperClient`) — no shared
/// instance to construct/hold since it's a singleton.
struct RouteManager {
    /// `route change default <gatewayIP>` — macOS BSD syntax omits "gw".
    func setDefaultRoute(gatewayIP: String) async throws {
        try await PrivilegedHelperClient.shared.setDefaultRoute(gatewayIP: gatewayIP)
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
    /// original default gateway if it changed. Mirrors
    /// `launcher.py:387-453`. Three independent XPC calls rather than one
    /// batched privileged command: today's batching existed purely to
    /// minimize *password dialogs* (one osascript prompt for the whole
    /// batch) — under XPC there's no per-call user-facing prompt at all
    /// (registration/approval is one one-time event, not per-call), so that
    /// motivation disappears entirely.
    func cleanupAfterDisconnect(
        vpnGatewayIP: String?,
        hostname: String?,
        noDefaultRoute: Bool,
        originalGatewayIP: String?
    ) async throws {
        if let vpnGatewayIP, !noDefaultRoute {
            try await PrivilegedHelperClient.shared.deleteDefaultRoute(gatewayIP: vpnGatewayIP)
        }

        if let hostname, let staleIP = resolveViaDSCacheUtil(hostname: hostname), !staleIP.isEmpty {
            try await PrivilegedHelperClient.shared.deleteHostRoute(ip: staleIP)
        }

        let currentGateway = NetworkInterfaces.defaultGatewayIP()
        if let originalGatewayIP, currentGateway != originalGatewayIP {
            try await PrivilegedHelperClient.shared.addDefaultRoute(gatewayIP: originalGatewayIP)
        }
    }
}
