import Foundation
import PulseVPNHelperProtocol

/// Accepts (or rejects) incoming XPC connections. The code-signing
/// requirement is set on the *listener itself* in `main.swift`
/// (`setConnectionCodeSigningRequirement`) — any connection from a process
/// that isn't our signed main app is rejected automatically before this
/// delegate method is even called, so no manual `SecCode` validation is
/// needed here.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
