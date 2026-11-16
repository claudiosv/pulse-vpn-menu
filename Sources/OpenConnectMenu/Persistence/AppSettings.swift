import Foundation

/// Global, app-wide preferences (as opposed to per-connection settings on
/// `ConnectionProfile`), persisted as JSON at
/// ~/Library/Application Support/OpenConnect Menu/settings.json.
@MainActor
final class AppSettings: ObservableObject {
    static let defaultStatsPollInterval: TimeInterval = 5
    static let statsPollIntervalRange: ClosedRange<TimeInterval> = 1...60

    @Published var statsPollInterval: TimeInterval {
        didSet { save() }
    }

    /// Whether Quit should stop the VPN session and clean up routes
    /// before the app exits. Defaults to `false` — quitting the menu bar
    /// app has never touched an active tunnel, and changing that default
    /// would silently drop a working VPN connection for anyone who quits
    /// the app without thinking about it.
    @Published var disconnectOnQuit: Bool {
        didSet { save() }
    }

    /// Post a macOS notification when openconnect exits without the user
    /// having asked for it (session expiry, `--reconnect-timeout` running
    /// out, a crash, an outside `kill`). Defaults to `true`: silently
    /// losing the tunnel is exactly what this exists to surface.
    @Published var notifyOnUnexpectedDisconnect: Bool {
        didSet { save() }
    }

    /// Also notify when openconnect loses the link but is still retrying
    /// on its own (the process stays alive for up to `--reconnect-timeout`),
    /// plus once more when it comes back. Defaults to `false` — flaky
    /// networks make this noisy.
    @Published var notifyOnTransientDrops: Bool {
        didSet { save() }
    }

    /// Keep the login browser's session cookies between connections, so
    /// single sign-on pages that use them don't ask again. Defaults to
    /// `false`: Chrome then also reopens its last tabs and is closed more
    /// slowly after login.
    @Published var keepBrowserSession: Bool {
        didSet { save() }
    }

    private struct Document: Codable {
        var statsPollInterval: TimeInterval
        var disconnectOnQuit: Bool
        var notifyOnUnexpectedDisconnect: Bool?
        var notifyOnTransientDrops: Bool?
        var keepBrowserSession: Bool?
    }

    init() {
        if let data = try? Data(contentsOf: AppPaths.appSettingsFile),
           let document = try? JSONDecoder().decode(Document.self, from: data) {
            statsPollInterval = document.statsPollInterval
            disconnectOnQuit = document.disconnectOnQuit
            notifyOnUnexpectedDisconnect = document.notifyOnUnexpectedDisconnect ?? true
            notifyOnTransientDrops = document.notifyOnTransientDrops ?? false
            keepBrowserSession = document.keepBrowserSession ?? false
        } else {
            statsPollInterval = Self.defaultStatsPollInterval
            disconnectOnQuit = false
            notifyOnUnexpectedDisconnect = true
            notifyOnTransientDrops = false
            keepBrowserSession = false
        }
    }

    private func save() {
        let document = Document(
            statsPollInterval: statsPollInterval,
            disconnectOnQuit: disconnectOnQuit,
            notifyOnUnexpectedDisconnect: notifyOnUnexpectedDisconnect,
            notifyOnTransientDrops: notifyOnTransientDrops,
            keepBrowserSession: keepBrowserSession
        )
        guard let data = try? JSONEncoder.pretty.encode(document) else { return }
        try? data.write(to: AppPaths.appSettingsFile, options: .atomic)
    }
}
