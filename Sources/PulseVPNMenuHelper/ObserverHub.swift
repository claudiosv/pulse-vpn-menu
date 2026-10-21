import Foundation
import PulseVPNHelperProtocol

/// The app connections currently listening for session changes. Each
/// accepted XPC connection registers itself here and is dropped when it goes
/// away; `broadcast` pushes a JSON `SessionStatus` to all of them.
final class ObserverHub: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]

    func add(_ connection: NSXPCConnection) {
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
    }

    func remove(_ connection: NSXPCConnection) {
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    func broadcast(_ status: Data) {
        let targets = lock.withLock { Array(connections.values) }
        for connection in targets {
            // No reply is expected, and a dead connection is cleaned up by
            // its own invalidation handler, so errors are ignored here.
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in }
            (proxy as? SessionObserverProtocol)?.sessionStatusChanged(status)
        }
    }
}
