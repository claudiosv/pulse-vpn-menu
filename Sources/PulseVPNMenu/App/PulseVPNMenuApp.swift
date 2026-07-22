import SwiftUI

@main
struct PulseVPNMenuApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(appState)
                .environmentObject(appState.connectionStore)
                .environmentObject(appState.controller)
        } label: {
            Image(nsImage: appState.statusImage)
        }
        // `.menu` (native NSMenu) can only ever host Text/Button/Divider as
        // real items — any image-based content (including the previous
        // offscreen-rendered chart) gets force-shrunk to icon size no
        // matter what size it's rendered at. `.window` hosts genuine
        // SwiftUI content instead (a real popover), so a live `Chart` can
        // be embedded directly in the dropdown at a normal, readable size.
        // Trade-off: none of the content below is a real NSMenuItem
        // anymore, so it's styled by hand (`MenuRow`) instead of getting
        // native menu appearance/keyboard nav for free.
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState.connectionStore)
        }
        .windowResizability(.contentSize)

        Window("Logs", id: "logs") {
            LogsView()
                .environmentObject(appState.logStore)
        }
        .windowResizability(.contentSize)

        Window("Stats", id: "stats") {
            StatsGraphView(stats: appState.controller.stats)
        }
        .windowResizability(.contentSize)
    }
}
