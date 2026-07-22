import AppKit
import SwiftUI

/// The menu bar dropdown's content: status line + live traffic graph,
/// Connect (flat or a submenu when there's more than one profile),
/// Disconnect, Reconnect, Settings/Logs/Stats windows, Quit.
///
/// `MenuBarExtra` is `.window`-styled (see `PulseVPNMenuApp`), so none of
/// this is a real `NSMenuItem` — it's plain SwiftUI content in a popover,
/// styled by hand with `MenuRow` to read like a native menu (hover
/// highlight, consistent padding) while actually supporting arbitrary
/// content like the embedded `Chart`, which native `NSMenu` items cannot.
struct MenuBarContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var controller: OpenConnectController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(appState.statusText)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            StatsGraphView(stats: controller.stats, compact: true)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)

            Divider()

            VStack(spacing: 1) {
                connectSection

                MenuRow(title: "Disconnect", systemImage: "xmark.circle") {
                    appState.disconnect()
                }
                .disabled(!appState.isConnected || controller.isBusy)

                MenuRow(title: "Reconnect", systemImage: "arrow.triangle.2.circlepath") {
                    appState.reconnect()
                }
                .disabled(!appState.isConnected || controller.isBusy)
            }
            .padding(.vertical, 6)

            Divider()

            VStack(spacing: 1) {
                MenuRow(title: "Settings…", systemImage: "gearshape") {
                    openAndFocus(id: "settings", title: "Settings")
                }
                MenuRow(title: "Logs…", systemImage: "doc.text") {
                    openAndFocus(id: "logs", title: "Logs")
                }
                MenuRow(title: "Stats…", systemImage: "chart.line.uptrend.xyaxis") {
                    openAndFocus(id: "stats", title: "Stats")
                }
            }
            .padding(.vertical, 6)

            Divider()

            VStack(spacing: 1) {
                MenuRow(title: "Quit", systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 300)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var connectSection: some View {
        let profiles = connectionStore.profiles
        if profiles.isEmpty {
            MenuRow(title: "Add a Connection…", systemImage: "plus.circle") {
                openAndFocus(id: "settings", title: "Settings")
            }
        } else if profiles.count == 1, let only = profiles.first {
            MenuRow(title: "Connect", systemImage: "bolt.fill") {
                appState.connect(profile: only)
            }
            .disabled(appState.isConnected || controller.isBusy)
        } else {
            Menu {
                ForEach(profiles) { profile in
                    Button(title(for: profile)) {
                        appState.connect(profile: profile)
                    }
                }
            } label: {
                Label("Connect", systemImage: "bolt.fill")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .disabled(appState.isConnected || controller.isBusy)
        }
    }

    private func title(for profile: ConnectionProfile) -> String {
        profile.id == connectionStore.defaultConnectionID ? "\(profile.name) (default)" : profile.name
    }

    /// `openWindow` alone shows the window but, since this is an
    /// `LSUIElement` agent app with no Dock icon, doesn't reliably bring the
    /// app or that specific window frontmost/key — e.g. clicking Settings
    /// while Logs is already open would leave Logs in front. Explicitly
    /// activate the app and raise the target window by title after asking
    /// SwiftUI to open/show it.
    private func openAndFocus(id: String, title: String) {
        openWindow(id: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.title == title }?.makeKeyAndOrderFront(nil)
        }
    }
}

/// A hand-styled stand-in for a native menu item: hover highlight, an
/// optional leading glyph, disabled-state dimming. Used throughout
/// `MenuBarContentView` since `.menuBarExtraStyle(.window)` content isn't
/// backed by real `NSMenuItem`s.
private struct MenuRow: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 16)
                }
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .secondary)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering && isEnabled ? Color.accentColor.opacity(0.18) : Color.clear)
                .padding(.horizontal, 6)
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
