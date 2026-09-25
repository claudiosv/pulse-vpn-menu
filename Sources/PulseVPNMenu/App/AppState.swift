import AppKit
import Foundation

/// Top-level coordinator: owns the persistence/VPN singletons and the
/// polled connection status shown in the menu bar (mirrors `menubar.py`'s
/// `refresh_status`, called from a 5s timer). `isBusy` itself is observed
/// directly from `controller` (it's event-driven, not polled), so views
/// bind to both `AppState` and `OpenConnectController` as needed.
@MainActor
final class AppState: ObservableObject {
    let connectionStore: ConnectionStore
    let logStore: LogStore
    let appSettings: AppSettings
    let controller: OpenConnectController

    @Published private(set) var statusText: String = "VPN: checking…"
    @Published private(set) var isConnected: Bool = false
    /// Snapshotted during `refresh()` (Timer-driven), not read live from
    /// `controller.connectedInterfaceDescription` inside a view — that
    /// getter calls `isConnected()`, which shells out to `/bin/ps`, and
    /// doing that synchronously from inside a SwiftUI view body crashes
    /// AttributeGraph (see `OpenConnectController.connectedSince`).
    @Published private(set) var connectedInterfaceDescription: String?

    /// Which section the main window shows. Lives here rather than in
    /// `MainWindowView`'s `@State` so the menu bar can open the window
    /// directly on a given tab ("Settings…" → General, "Logs…" → Logs).
    @Published var selectedTab: MainTab = .status

    /// How often the menu bar / status text refreshes from `controller`'s
    /// polled state — independent of `AppSettings.statsPollInterval`
    /// (which governs how often openconnect itself is asked for RX/TX
    /// stats), even though both happened to share one constant before.
    private static let statusRefreshInterval: TimeInterval = 5

    private var refreshTimer: Timer?

    init() {
        let connectionStore = ConnectionStore()
        let appSettings = AppSettings()
        let logStore = LogStore(appSettings: appSettings)
        let controller = OpenConnectController(logStore: logStore, appSettings: appSettings)
        self.connectionStore = connectionStore
        self.logStore = logStore
        self.appSettings = appSettings
        self.controller = controller
        controller.profileName = { [weak connectionStore] id in
            connectionStore?.profile(id: id)?.name
        }

        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.statusRefreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        // Piggybacks on this timer to notice openconnect exiting without
        // being asked to; that path cleans up and re-refreshes when done.
        Task {
            await controller.handleUnexpectedExitIfNeeded()
        }
        let connected = controller.isConnected()
        isConnected = connected
        connectedInterfaceDescription = connected ? controller.connectedInterfaceDescription : nil
        if controller.isBusy {
            statusText = "VPN: working…"
        } else if connected {
            let detail = connectedInterfaceDescription.map { " (\($0))" } ?? ""
            statusText = "VPN: connected\(detail)"
        } else {
            statusText = "VPN: disconnected"
        }
    }

    /// The profile the UI is "about": the one the live tunnel actually
    /// belongs to while connected, otherwise the default that a fresh
    /// Connect would use.
    var activeProfile: ConnectionProfile? {
        if let id = controller.connectedProfileID, let profile = connectionStore.profile(id: id) {
            return profile
        }
        return connectionStore.defaultProfile
    }

    /// Headline for the Status tab. `statusText` stays as-is for the menu
    /// bar, where the "VPN: …" prefix is the only thing identifying what
    /// the line refers to.
    var statusTitle: String {
        if controller.isBusy { return "Working…" }
        guard isConnected else { return "Not Connected" }
        guard let name = activeProfile?.name, !name.isEmpty else { return "Connected" }
        return "Connected to \(name)"
    }

    var statusDetail: String {
        if controller.isBusy { return "Talking to openconnect…" }
        guard isConnected else {
            return connectionStore.profiles.isEmpty
                ? "Add a connection to get started"
                : "Click the button to connect"
        }
        if let interface = connectedInterfaceDescription {
            return "Tunnel active · \(interface)"
        }
        return "Tunnel active · click to disconnect"
    }

    /// What the Status tab's power button does. With no profiles saved
    /// there's nothing to connect to, so it sends the user to Connections
    /// instead of failing silently.
    func toggleConnect() {
        guard !controller.isBusy else { return }
        if isConnected {
            disconnect()
        } else if let profile = connectionStore.defaultProfile {
            connect(profile: profile)
        } else {
            selectedTab = .connections
        }
    }

    /// Standard macOS menu bar icon size (points). The source PNGs are
    /// 40x40px with no @2x scale-factor metadata, so without this
    /// `NSImage.size` defaults to 40x40 *points* and AppKit renders it at
    /// roughly double the normal menu bar icon size, blown up and blurry.
    private static let menuBarIconSize = NSSize(width: 18, height: 18)

    var statusImage: NSImage {
        let name = isConnected ? "menubar-connected" : "menubar-disconnected"
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = Self.menuBarIconSize
            image.isTemplate = true
            return image
        }
        return NSImage(size: Self.menuBarIconSize)
    }

    func connect(profile: ConnectionProfile) {
        Task {
            await controller.connect(profile: profile, store: connectionStore)
            refresh()
        }
    }

    func disconnect() {
        Task {
            await controller.disconnect()
            refresh()
        }
    }

    func reconnect() {
        Task {
            do {
                try await controller.reconnect()
            } catch {
                logStore.append("Reconnect failed: \(error)\n")
            }
        }
    }
}
