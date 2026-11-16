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
        let status = service.status
        switch status {
        case .notRegistered:
            // Nothing registered (a fresh install, or already removed).
            UserDefaults.standard.set(true, forKey: doneKey)
        default:
            log("Retired helper daemon status: \(status) (\(status.rawValue)); unregistering.\n")
            do {
                try await service.unregister()
                log("Removed the retired helper daemon from Login Items.\n")
                UserDefaults.standard.set(true, forKey: doneKey)
            } catch {
                // Typically the system no longer links the service to this
                // app (status notFound), so only a manual removal works.
                // Don't keep trying on every launch.
                log("Could not remove the retired helper daemon: \(error.localizedDescription). Remove it by hand: sudo launchctl bootout system/com.claudiosv.pulse-vpn-menu.helper\n")
                UserDefaults.standard.set(true, forKey: doneKey)
            }
        }
    }
}
