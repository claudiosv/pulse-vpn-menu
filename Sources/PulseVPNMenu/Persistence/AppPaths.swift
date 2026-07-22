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
    static let chromeProfileDir = appSupportDir.appendingPathComponent("chrome-profile", isDirectory: true)

    static let logsDir: URL = {
        let dir = appSupportDir.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        return dir
    }()

    static let currentLogFile = logsDir.appendingPathComponent("current.log")

    /// Fixed, stable path: always holds the most recently launched
    /// openconnect's real PID. The unprivileged app itself writes this
    /// immediately after the privileged helper hands back the real PID
    /// (the helper spawns openconnect directly and reports its PID
    /// synchronously — no more sudo-forking workaround needed to discover
    /// it). This is what lets a relaunched app reattach to an
    /// already-running tunnel after a crash (see
    /// `OpenConnectController.recoverStateFromPidFile`), entirely
    /// unprivileged.
    static let openconnectPidFile = logsDir.appendingPathComponent("openconnect.pid")

    /// Ensures the log file exists (world-writable, since the privileged
    /// helper's `FileHandle(forWritingAtPath:)` requires it to already
    /// exist) and the pid file exists, before a new connection attempt.
    static func prepareForNewConnection() throws {
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        for file in [currentLogFile, openconnectPidFile] {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o666])
        }
    }
}
