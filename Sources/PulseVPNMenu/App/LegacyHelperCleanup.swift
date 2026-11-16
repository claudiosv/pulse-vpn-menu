import Foundation
import ServiceManagement

/// The app used to install a root helper daemon
/// (`com.claudiosv.pulse-vpn-menu.helper`) that stayed registered in Login
/// Items until switched off by hand. The packet tunnel replaced it, so on
/// first launch the app unregisters it once. The helper's launchd plist is
/// still bundled (`Resources/LegacyHelper`) because that is how
/// `SMAppService` finds the service.
@MainActor
enum LegacyHelperCleanup {
    private static let plistName = "com.claudiosv.pulse-vpn-menu.helper.plist"
    private static let doneKey = "legacyHelperCleanupDone"

    static func runOnce(log: (String) -> Void) async {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let service = SMAppService.daemon(plistName: plistName)
        switch service.status {
        case .notRegistered, .notFound:
            // Nothing registered (a fresh install, or already removed).
            UserDefaults.standard.set(true, forKey: doneKey)
        default:
            do {
                try await service.unregister()
                log("Removed the retired helper daemon from Login Items.\n")
                UserDefaults.standard.set(true, forKey: doneKey)
            } catch {
                // Tried again next launch.
                log("Could not remove the retired helper daemon: \(error.localizedDescription)\n")
            }
        }
    }
}
