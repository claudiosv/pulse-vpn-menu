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

    /// Whether Quit stops the VPN (and with it the network extension's
    /// session) before the app exits. Defaults to `true`: once the app is
    /// gone nothing can sign a dropped tunnel back in or show its state.
    /// Stored as `stopOnQuit`; an older `disconnectOnQuit` value, whose
    /// default was off, is ignored on purpose. Quitting by `kill -TERM`
    /// (how a rebuilt app is relaunched) bypasses this, so a relaunch keeps
    /// the tunnel.
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
        /// Replaced by `stopOnQuit`, whose default is on; kept so older files
        /// still decode, and otherwise ignored.
        var disconnectOnQuit: Bool?
        var stopOnQuit: Bool?
        var notifyOnUnexpectedDisconnect: Bool?
        var notifyOnTransientDrops: Bool?
        var keepBrowserSession: Bool?
    }

    init() {
        if let data = try? Data(contentsOf: AppPaths.appSettingsFile),
           let document = try? JSONDecoder().decode(Document.self, from: data) {
            statsPollInterval = document.statsPollInterval
            disconnectOnQuit = document.stopOnQuit ?? true
            notifyOnUnexpectedDisconnect = document.notifyOnUnexpectedDisconnect ?? true
            notifyOnTransientDrops = document.notifyOnTransientDrops ?? false
            keepBrowserSession = document.keepBrowserSession ?? false
        } else {
            statsPollInterval = Self.defaultStatsPollInterval
            disconnectOnQuit = true
            notifyOnUnexpectedDisconnect = true
            notifyOnTransientDrops = false
            keepBrowserSession = false
        }
    }

    private func save() {
        let document = Document(
            statsPollInterval: statsPollInterval,
            disconnectOnQuit: nil,
            stopOnQuit: disconnectOnQuit,
            notifyOnUnexpectedDisconnect: notifyOnUnexpectedDisconnect,
            notifyOnTransientDrops: notifyOnTransientDrops,
            keepBrowserSession: keepBrowserSession
        )
        guard let data = try? JSONEncoder.pretty.encode(document) else { return }
        try? data.write(to: AppPaths.appSettingsFile, options: .atomic)
    }
}
