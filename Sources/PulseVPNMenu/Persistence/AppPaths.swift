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
    /// openconnect's real PID, written immediately when it starts. Safe to
    /// reuse across attempts (unlike the exit file below) because that
    /// write only ever happens once, right at launch — never lazily at
    /// process end — so an old attempt can't clobber a newer one's pid.
    /// This is also what lets a relaunched app reattach to an
    /// already-running tunnel after a crash (see
    /// `OpenConnectController.recoverStateFromPidFile`).
    static let openconnectPidFile = logsDir.appendingPathComponent("openconnect.pid")

    /// A fresh, uniquely-named exit-code file for one connection attempt.
    /// Unlike the PID file, this *is* written lazily — only once the
    /// process eventually terminates — so reusing one fixed path let an
    /// old, still-pending attempt (e.g. an orphaned openconnect from a
    /// previous hang) overwrite a brand-new attempt's exit file with stale
    /// data the moment the old process finally exited, making the app
    /// think a perfectly healthy new connection had already died.
    static func newExitFile() -> URL {
        logsDir.appendingPathComponent("openconnect-\(UUID().uuidString).exit")
    }

    /// Ensures the log/pid files exist and are world-readable so the
    /// root-owned openconnect process (writing logFile/pidFile) and this
    /// unprivileged process can both read/write them without games.
    static func prepareForNewConnection() throws {
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        for file in [currentLogFile, openconnectPidFile] {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o666])
        }
    }
}
