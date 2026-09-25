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

    /// One window for everything. Settings, Logs, and Stats used to be
    /// three separate `NSWindow`s reached from three separate menu items;
    /// they're now tabs of `MainWindowView`, so the menu items below all
    /// raise this same window and just select a different tab.
    private lazy var mainWindow: NSWindow = {
        let window = makeWindow(title: "Pulse VPN Menu", minSize: NSSize(width: 720, height: 620)) {
            MainWindowView(appState: self.appState)
                .environmentObject(self.appState.connectionStore)
                .environmentObject(self.appState.appSettings)
                .environmentObject(self.appState.logStore)
        }
        // The tab picker is the window's real header, so the title bar is
        // left transparent and empty — only the traffic lights show.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        return window
    }()

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
            rootView: MenuHeaderView(
                appState: appState,
                stats: appState.controller.stats,
                connectionStore: appState.connectionStore
            )
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
        menu.addItem(actionItem(title: "Open Pulse VPN Menu…") { [weak self] in self?.showMain(tab: .status) })
        let settingsItem = actionItem(title: "Settings…") { [weak self] in self?.showMain(tab: .general) }
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(actionItem(title: "Logs…") { [weak self] in self?.showMain(tab: .logs) })

        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Quit") { [weak self] in self?.quit() })

        return menu
    }

    /// Quitting never touched an active tunnel before (see
    /// `AppSettings.disconnectOnQuit`'s doc comment) — that default is
    /// preserved here. Only when the user has opted in and a tunnel is
    /// actually up do we run the same `disconnect()` teardown a manual
    /// Disconnect click would, and only call `terminate(nil)` once that has
    /// actually finished (rather than firing it off and quitting
    /// immediately, which would race the route cleanup).
    private func quit() {
        guard appState.appSettings.disconnectOnQuit, appState.isConnected else {
            NSApplication.shared.terminate(nil)
            return
        }
        Task {
            appState.logStore.append("Disconnecting before quitting…\n")
            await appState.controller.disconnect()
            NSApplication.shared.terminate(nil)
        }
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
            setAction(on: connectItem) { [weak self] in self?.showMain(tab: .connections) }
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
    /// scene — this is an `LSUIElement` agent app with no Dock icon by
    /// default (see `showMain(tab:)`, which switches to a Dock icon the
    /// first time this window is opened and keeps it for the rest of the
    /// session — `applicationShouldHandleReopen(_:hasVisibleWindows:)`
    /// below then makes clicking that Dock icon reopen the status bar menu
    /// rather than a blank window), and SwiftUI's `openWindow(id:)` doesn't
    /// reliably bring such a window (or the app itself) frontmost. Owning
    /// the `NSWindow` directly lets
    /// `showMain(tab:)` activate the app and raise it synchronously instead
    /// of needing a `DispatchQueue.main.asyncAfter` guess. `isReleasedWhenClosed
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
        // `NSHostingController`'s fitting size is only as good as the
        // hosted view's intrinsic size; a view whose tabs are all
        // `ScrollView`s (no intrinsic size of their own) can't be trusted
        // to produce a sane initial frame from that alone, so pin it
        // explicitly rather than hoping `minSize` is what gets picked.
        window.setContentSize(minSize)
        window.center()
        return window
    }

    private func showMain(tab: MainTab) {
        appState.selectedTab = tab
        // Gain a Dock icon (and Cmd+Tab presence) for the rest of the
        // session, not just while this window is open — it never reverts
        // to `.accessory`. Clicking that Dock icon later (with no window
        // open) is handled below by reopening the status bar menu instead
        // of this window.
        NSApp.setActivationPolicy(.regular)
        // `activate`/`makeKeyAndOrderFront` right after `setActivationPolicy`
        // can land before the Dock has processed the policy change, which is
        // what leaves the new tile without its running-app indicator dot.
        // Giving it one run-loop hop first is the standard fix.
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.mainWindow.makeKeyAndOrderFront(nil)
        }
    }

    /// Fires when the Dock icon is clicked while the app has no visible
    /// window (e.g. after closing `mainWindow`, or right after launch on
    /// the rare path where `.regular` was already set). There's no window
    /// scene for AppKit to reopen on its own, so this stands in for that:
    /// popping the same status bar menu a click on the menu bar icon would.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        statusItem.button?.performClick(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
    @ObservedObject var connectionStore: ConnectionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(appState.isConnected ? Color.green : Color.secondary.opacity(0.6))
                    .frame(width: 9, height: 9)
                Text(appState.statusText)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            if let profile = appState.activeProfile {
                Text(profile.vpnURL)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 14)
                    .padding(.leading, 17)
                    .padding(.top, 2)
            }

            StatsGraphView(stats: stats, style: .menu)
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 4)
        }
        .frame(width: 300)
    }
}
