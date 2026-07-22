import AppKit

/// Bypasses SwiftUI's `App`/`Scene` lifecycle entirely. A `Settings`
/// scene — the usual "placeholder with no visible window" for a
/// pure-AppKit menu bar app — turned out to still auto-show itself as an
/// empty window at launch; there's no `Scene` that reliably produces zero
/// windows. Driving `NSApplication` directly sidesteps the question:
/// nothing appears at launch except what `AppDelegate
/// .applicationDidFinishLaunching` explicitly creates (the status item),
/// exactly like the privileged helper's own `main.swift` entry point.
@main
enum PulseVPNMenuMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
