import Foundation
import PulseVPNHelperProtocol

/// Accepts (or rejects) incoming XPC connections. The code-signing
/// requirement is set on the *listener itself* in `main.swift`
/// (`setConnectionCodeSigningRequirement`) — any connection from a process
/// that isn't our signed main app is rejected automatically before this
/// delegate method is even called, so no manual `SecCode` validation is
/// needed here.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        connection.exportedObject = service
        // The app exports a `SessionObserverProtocol` on its side of the
        // connection; session changes are pushed through it.
        connection.remoteObjectInterface = NSXPCInterface(with: SessionObserverProtocol.self)
        service.observers.add(connection)
        connection.invalidationHandler = { [weak service, weak connection] in
            if let connection { service?.observers.remove(connection) }
        }
        connection.resume()
        return true
    }
}
