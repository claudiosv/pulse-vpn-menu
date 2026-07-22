import Foundation

/// Global, app-wide preferences (as opposed to per-connection settings on
/// `ConnectionProfile`), persisted as JSON at
/// ~/Library/Application Support/Pulse VPN Menu/settings.json.
@MainActor
final class AppSettings: ObservableObject {
    static let defaultStatsPollInterval: TimeInterval = 5
    static let statsPollIntervalRange: ClosedRange<TimeInterval> = 1...60

    @Published var statsPollInterval: TimeInterval {
        didSet { save() }
    }

    /// Whether Quit should send SIGTERM to openconnect and clean up routes
    /// before the app exits. Defaults to `false` — quitting the menu bar
    /// app has never touched an active tunnel, and changing that default
    /// would silently drop a working VPN connection for anyone who quits
    /// the app without thinking about it.
    @Published var disconnectOnQuit: Bool {
        didSet { save() }
    }

    /// Every SIGUSR1 stats poll makes openconnect re-print the same four
    /// lines (`Configured as ...`, `Session authentication will expire
    /// at ...`, `RX: ... TX: ...`, `SSL ciphersuite: ...`) with fresh
    /// values, which floods the Logs window over a long-running
    /// connection. When on, `LogStore` shows only the first occurrence of
    /// each per connection (still re-shown after a relaunch/reattach or a
    /// fresh connect) and hides the repeats — the underlying stats are
    /// still parsed and graphed either way, this only affects what's
    /// displayed. Defaults to `true`: the repeats are rarely useful and
    /// this is the behavior actually being asked for.
    @Published var hideRepeatedStatsLines: Bool {
        didSet { save() }
    }

    private struct Document: Codable {
        var statsPollInterval: TimeInterval
        var disconnectOnQuit: Bool
        var hideRepeatedStatsLines: Bool?
    }

    init() {
        if let data = try? Data(contentsOf: AppPaths.appSettingsFile),
           let document = try? JSONDecoder().decode(Document.self, from: data) {
            statsPollInterval = document.statsPollInterval
            disconnectOnQuit = document.disconnectOnQuit
            hideRepeatedStatsLines = document.hideRepeatedStatsLines ?? true
        } else {
            statsPollInterval = Self.defaultStatsPollInterval
            disconnectOnQuit = false
            hideRepeatedStatsLines = true
        }
    }

    private func save() {
        let document = Document(
            statsPollInterval: statsPollInterval,
            disconnectOnQuit: disconnectOnQuit,
            hideRepeatedStatsLines: hideRepeatedStatsLines
        )
        guard let data = try? JSONEncoder.pretty.encode(document) else { return }
        try? data.write(to: AppPaths.appSettingsFile, options: .atomic)
    }
}
