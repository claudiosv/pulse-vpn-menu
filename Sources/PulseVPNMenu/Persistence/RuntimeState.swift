import Foundation

/// The VPN session the app is currently following. Nothing is persisted:
/// the tunnel belongs to the system (Network Extension), which is asked at
/// launch whether one is up — see `OpenConnectController.reattachIfRunning`.
struct RuntimeState: Equatable {
    var profileID: UUID?
    var startedAt: Date
}
