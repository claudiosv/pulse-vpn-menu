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

    private struct Document: Codable {
        var statsPollInterval: TimeInterval
        var disconnectOnQuit: Bool
    }

    init() {
        if let data = try? Data(contentsOf: AppPaths.appSettingsFile),
           let document = try? JSONDecoder().decode(Document.self, from: data) {
            statsPollInterval = document.statsPollInterval
            disconnectOnQuit = document.disconnectOnQuit
        } else {
            statsPollInterval = Self.defaultStatsPollInterval
            disconnectOnQuit = false
        }
    }

    private func save() {
        let document = Document(statsPollInterval: statsPollInterval, disconnectOnQuit: disconnectOnQuit)
        guard let data = try? JSONEncoder.pretty.encode(document) else { return }
        try? data.write(to: AppPaths.appSettingsFile, options: .atomic)
    }
}
