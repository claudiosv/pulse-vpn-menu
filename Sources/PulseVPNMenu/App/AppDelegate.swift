import AppKit
import Combine
import SwiftUI

/// Owns the actual menu bar presence: a native `NSStatusItem` + `NSMenu`
/// instead of a SwiftUI `MenuBarExtra`. `.menuBarExtraStyle(.window)` gave
/// free-form SwiftUI content, but none of it was a real `NSMenuItem` — no
/// native hover highlight, padding, or keyboard navigation, and it visibly
/// read as non-native. `.menu` style forces every item into
/// Text/Button/Divider and silently force-shrinks anything else (including
/// a live `Chart`) to icon size. Going straight to `NSMenu` avoids both
/// problems: every item below is real and OS-rendered except the live
/// traffic graph, which is embedded via `NSHostingView` as a single
/// `NSMenuItem.view` — the documented escape hatch for mixing SwiftUI
/// content into an otherwise fully native menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let appState = AppState()

    private var statusItem: NSStatusItem!
    private var cancellables: Set<AnyCancellable> = []

    private var connectItem: NSMenuItem!
    private var disconnectItem: NSMenuItem!
    private var reconnectItem: NSMenuItem!

    private lazy var settingsWindow = makeWindow(title: "Settings", minSize: NSSize(width: 480, height: 360)) {
        SettingsView().environmentObject(self.appState.connectionStore)
    }
    private lazy var logsWindow = makeWindow(title: "Logs", minSize: NSSize(width: 640, height: 400)) {
        LogsView().environmentObject(self.appState.logStore)
    }
    private lazy var statsWindow = makeWindow(title: "Stats", minSize: NSSize(width: 520, height: 360)) {
        StatsGraphView(stats: self.appState.controller.stats)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = appState.statusImage
        item.menu = buildMenu()
        statusItem = item

        // The menu's own items only need refreshing right before it opens
        // (`menuNeedsUpdate`), but the status bar icon itself must update
        // live even while the menu is closed.
        appState.$isConnected
            .sink { [weak self] _ in
                guard let self else { return }
                self.statusItem.button?.image = self.appState.statusImage
            }
            .store(in: &cancellables)
    }

    // MARK: - Menu construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let header = NSHostingView(
            rootView: MenuHeaderView(appState: appState, stats: appState.controller.stats)
        )
        header.frame.size = header.fittingSize
        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)

        menu.addItem(.separator())

        connectItem = NSMenuItem(title: "Connect", action: nil, keyEquivalent: "")
        menu.addItem(connectItem)

        disconnectItem = actionItem(title: "Disconnect") { [weak self] in
            self?.appState.disconnect()
        }
        menu.addItem(disconnectItem)

        reconnectItem = actionItem(title: "Reconnect") { [weak self] in
            self?.appState.reconnect()
        }
        menu.addItem(reconnectItem)

        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Settings…") { [weak self] in self?.show(self?.settingsWindow) })
        menu.addItem(actionItem(title: "Logs…") { [weak self] in self?.show(self?.logsWindow) })
        menu.addItem(actionItem(title: "Stats…") { [weak self] in self?.show(self?.statsWindow) })

        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Quit") { NSApplication.shared.terminate(nil) })

        return menu
    }

    /// Refreshes everything that can change between menu opens: the
    /// Connect item's title/action/submenu (the profile list can change any
    /// time via Settings) and every item's enabled state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let profiles = appState.connectionStore.profiles
        let connected = appState.isConnected
        let busy = appState.controller.isBusy

        connectItem.submenu = nil

        if profiles.isEmpty {
            connectItem.title = "Add a Connection…"
            setAction(on: connectItem) { [weak self] in self?.show(self?.settingsWindow) }
        } else if profiles.count == 1, let only = profiles.first {
            connectItem.title = "Connect"
            setAction(on: connectItem) { [weak self] in self?.appState.connect(profile: only) }
        } else {
            connectItem.title = "Connect"
            connectItem.action = nil
            connectItem.target = nil
            let submenu = NSMenu()
            for profile in profiles {
                let title = profile.id == appState.connectionStore.defaultConnectionID
                    ? "\(profile.name) (default)" : profile.name
                submenu.addItem(actionItem(title: title) { [weak self] in self?.appState.connect(profile: profile) })
            }
            connectItem.submenu = submenu
        }

        connectItem.isEnabled = !connected && !busy
        disconnectItem.isEnabled = connected && !busy
        reconnectItem.isEnabled = connected && !busy
    }

    // MARK: - Windows

    /// A plain `NSWindow` + `NSHostingController`, not a SwiftUI `Window`
    /// scene — this is an `LSUIElement` agent app with no Dock icon, and
    /// SwiftUI's `openWindow(id:)` doesn't reliably bring such a window (or
    /// the app itself) frontmost. Owning the `NSWindow` directly lets
    /// `show(_:)` activate the app and raise it synchronously instead of
    /// needing a `DispatchQueue.main.asyncAfter` guess. `isReleasedWhenClosed
    /// = false` keeps the instance (and its state) alive across the red
    /// close button, matching the old scene-backed windows' behavior.
    private func makeWindow<V: View>(
        title: String,
        minSize: NSSize,
        @ViewBuilder content: @escaping () -> V
    ) -> NSWindow {
        let hosting = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = minSize
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func show(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Action bridging

    /// `NSMenuItem` has no closure-based action API — bridge via a target
    /// object that owns the closure, retained by the menu item itself
    /// (`representedObject`) so it lives exactly as long as the item does.
    private func actionItem(title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        setAction(on: item, action: action)
        return item
    }

    private func setAction(on item: NSMenuItem, action: @escaping () -> Void) {
        let sleeve = ActionSleeve(action: action)
        item.target = sleeve
        item.action = #selector(ActionSleeve.invoke)
        item.representedObject = sleeve
    }
}

/// Retains a closure so it can be used as an `NSMenuItem` target/action.
private final class ActionSleeve: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}

/// The one non-native piece of the menu: status text + live traffic graph,
/// embedded via `NSHostingView`. Declared as its own `View` (rather than an
/// inline literal at the `NSHostingView` call site) specifically so
/// `@ObservedObject` observation works and the hosted view keeps updating
/// in place as `AppState`/`StatsHistory` publish changes, exactly like it
/// did as SwiftUI popover content before.
private struct MenuHeaderView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var stats: StatsHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(appState.statusText)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
            StatsGraphView(stats: stats, compact: true)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
        }
        .frame(width: 300)
    }
}
