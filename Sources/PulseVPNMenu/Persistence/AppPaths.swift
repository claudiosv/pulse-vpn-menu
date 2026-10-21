import Foundation

/// Central location for every on-disk path the app reads or writes.
enum AppPaths {
    static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Pulse VPN Menu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let connectionsFile = appSupportDir.appendingPathComponent("connections.json")
    static let runtimeStateFile = appSupportDir.appendingPathComponent("runtime-state.json")
    static let appSettingsFile = appSupportDir.appendingPathComponent("settings.json")
    static let chromeProfileDir = appSupportDir.appendingPathComponent("chrome-profile", isDirectory: true)

    static let logsDir: URL = {
        let dir = appSupportDir.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        return dir
    }()

    static let currentLogFile = logsDir.appendingPathComponent("current.log")

    /// Durable, append-only record of everything the app itself has
    /// logged (`LogStore.append`) — registration status, connect
    /// failures, reattach confirmations, route errors, etc. — with a
    /// timestamp on every line. Unlike `currentLogFile` (openconnect's own
    /// raw output, truncated at the start of every connection attempt),
    /// this file is never cleared, so it survives across connections and
    /// app relaunches as a running diagnostic history.
    static let appLogFile = logsDir.appendingPathComponent("app.log")

    /// Ensures the log file exists (world-writable, since the privileged
    /// helper's `FileHandle(forWritingAtPath:)` requires it to already
    /// exist) before a new connection attempt.
    static func prepareForNewConnection() throws {
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        for file in [currentLogFile] {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o666])
        }
    }
}
