import SwiftUI

/// The window's four sections. Also drives deep-linking from the menu bar
/// ("Settings…" opens the window straight on `.general`), which is why the
/// selection lives on `AppState` rather than in this view's `@State`.
enum MainTab: String, CaseIterable, Identifiable {
    case status = "Status"
    case connections = "Connections"
    case logs = "Logs"
    case general = "General"

    var id: String { rawValue }
}

/// Single window shell: a centered segmented tab picker over the active
/// tab. This replaces the three separate `NSWindow`s the app used to open
/// from the menu (Settings, Logs, Stats) — the stats graph is now part of
/// Status, and Settings' two `TabView` tabs became Connections + General.
struct MainWindowView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var controller: OpenConnectController

    init(appState: AppState) {
        self._appState = ObservedObject(wrappedValue: appState)
        self._controller = ObservedObject(wrappedValue: appState.controller)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            Group {
                switch appState.selectedTab {
                case .status:
                    StatusView(appState: appState, controller: controller)
                case .connections:
                    ConnectionsView(appState: appState, controller: controller)
                case .logs:
                    LogsView()
                case .general:
                    GeneralView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.ultraThinMaterial)
        // Every tab is a `ScrollView`, which has no intrinsic content size
        // of its own — without an explicit ideal size here,
        // `NSHostingController` has nothing to size the window from and
        // the window opens at whatever leftover/default frame AppKit picks
        // (see `AppDelegate.makeWindow`, which also pins an initial
        // `setContentSize` from this same value as a second line of
        // defense).
        .frame(minWidth: 720, idealWidth: 720, minHeight: 620, idealHeight: 620)
    }

    private var header: some View {
        Picker("", selection: $appState.selectedTab) {
            ForEach(MainTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
