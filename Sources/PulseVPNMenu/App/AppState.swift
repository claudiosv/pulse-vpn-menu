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

    /// How often the menu bar / status text refreshes from `controller`'s
    /// polled state — independent of `AppSettings.statsPollInterval`
    /// (which governs how often openconnect itself is asked for RX/TX
    /// stats), even though both happened to share one constant before.
    private static let statusRefreshInterval: TimeInterval = 5

    private var refreshTimer: Timer?

    init() {
        let connectionStore = ConnectionStore()
        let logStore = LogStore()
        let appSettings = AppSettings()
        let controller = OpenConnectController(logStore: logStore, appSettings: appSettings)
        self.connectionStore = connectionStore
        self.logStore = logStore
        self.appSettings = appSettings
        self.controller = controller

        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.statusRefreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        let connected = controller.isConnected()
        isConnected = connected
        if controller.isBusy {
            statusText = "VPN: working…"
        } else if connected {
            let detail = controller.connectedInterfaceDescription.map { " (\($0))" } ?? ""
            statusText = "VPN: connected\(detail)"
        } else {
            statusText = "VPN: disconnected"
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
