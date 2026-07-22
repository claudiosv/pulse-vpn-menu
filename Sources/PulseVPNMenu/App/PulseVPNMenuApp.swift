import SwiftUI

/// The menu bar presence, Settings/Logs/Stats windows, and Connect/
/// Disconnect/Reconnect wiring all live in `AppDelegate` now (a real
/// `NSStatusItem` + `NSMenu`, not a SwiftUI `MenuBarExtra` scene) — this
/// `App` only needs to exist to host the delegate adaptor and satisfy
/// SwiftUI's `Scene` requirement with something that shows no UI of its
/// own.
@main
struct PulseVPNMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
