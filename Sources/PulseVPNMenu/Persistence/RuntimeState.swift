import Foundation

/// Persisted record of the currently-running openconnect process (if any),
/// so relaunching the app can rediscover a live tunnel and still offer
/// Disconnect/Reconnect instead of losing track of it.
struct RuntimeState: Codable, Equatable {
    var pid: Int32
    /// nil when the state was reconstructed purely from the PID file (e.g.
    /// after the app crashed/was killed and relaunched) without the full
    /// context a normal `connectOnce()` attempt has.
    var profileID: UUID?
    var startedAt: Date
    var vpnGatewayIP: String?
    var originalGatewayIP: String?
    var hostname: String?
    var noDefaultRoute: Bool

    static func load() -> RuntimeState? {
        guard let data = try? Data(contentsOf: AppPaths.runtimeStateFile) else { return nil }
        return try? JSONDecoder().decode(RuntimeState.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder.pretty.encode(self) else { return }
        try? data.write(to: AppPaths.runtimeStateFile, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: AppPaths.runtimeStateFile)
    }
}
