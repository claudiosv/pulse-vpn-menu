import SwiftUI

@main
struct VPNHelperApp: App {
    @StateObject private var store = VPNStore()

    var body: some Scene {
        // Main window
        Window("VPN Helper", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 720, idealWidth: 720, minHeight: 600, idealHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // Menu bar item
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
        } label: {
            Image(systemName: store.isConnected ? "lock.shield.fill" : "lock.shield")
        }
        .menuBarExtraStyle(.window)
    }
}
