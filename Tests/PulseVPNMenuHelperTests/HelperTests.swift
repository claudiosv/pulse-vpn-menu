import Foundation
import PulseVPNHelperProtocol
import Testing
@testable import PulseVPNMenuHelper

@Suite struct RequestValidationTests {
    private let logDir = "/Users/someone/Library/Application Support/Pulse VPN Menu/Logs"

    @Test func acceptsOnlyTheSessionLog() throws {
        #expect(try RequestValidation.sessionLogPath("\(logDir)/current.log") == "\(logDir)/current.log")

        for bad in [
            "/etc/hosts",
            "\(logDir)/app.log",
            "\(logDir)/../../../../../../etc/hosts",   // traversal collapses to a different path
            "/private/var/root/Library/Application Support/Pulse VPN Menu/Logs/current.log",
            "relative/current.log",
        ] {
            #expect(throws: HelperError.self) { try RequestValidation.sessionLogPath(bad) }
        }
    }

    @Test func requiresHTTPSURLs() throws {
        _ = try RequestValidation.vpnURL("https://vpn.example.edu/emp")
        for bad in ["http://vpn.example.edu", "ftp://x", "file:///etc/passwd", "vpn.example.edu", ""] {
            #expect(throws: HelperError.self) { try RequestValidation.vpnURL(bad) }
        }
    }

    @Test func requiresPlainIPv4ForRoutes() throws {
        _ = try RequestValidation.ipv4("172.25.228.228")
        for bad in ["-inet6", "10.0.0", "10.0.0.256", "1.2.3.4 -foo", "::1", "example.com", ""] {
            #expect(throws: HelperError.self) { try RequestValidation.ipv4(bad) }
        }
    }
}

/// The app side of the reverse interface, as a test double.
private final class TestObserver: NSObject, SessionObserverProtocol, @unchecked Sendable {
    let statuses: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    override init() {
        (statuses, continuation) = AsyncStream.makeStream()
        super.init()
    }

    func sessionStatusChanged(_ status: Data) { continuation.yield(status) }
}

/// Real XPC over an anonymous listener: same interfaces and delegate the
/// daemon uses, minus the mach service and code-signing requirement.
@Suite struct HelperXPCTests {
    private struct Rig {
        let delegate: HelperListenerDelegate
        let listener: NSXPCListener
        let connection: NSXPCConnection
        let observer: TestObserver

        func helper() -> PrivilegedHelperProtocol {
            connection.remoteObjectProxyWithErrorHandler { error in
                Issue.record("XPC error: \(error)")
            } as! PrivilegedHelperProtocol
        }
    }

    private func makeRig() -> Rig {
        let delegate = HelperListenerDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()

        let observer = TestObserver()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: SessionObserverProtocol.self)
        connection.exportedObject = observer
        connection.resume()
        return Rig(delegate: delegate, listener: listener, connection: connection, observer: observer)
    }

    @Test func reportsItsProtocolVersion() async {
        let rig = makeRig()
        defer { rig.connection.invalidate() }
        let version: Int = await withCheckedContinuation { continuation in
            rig.helper().protocolVersion { continuation.resume(returning: $0) }
        }
        #expect(version == PrivilegedHelperConstants.protocolVersion)
    }

    @Test func statusBeforeAnySessionIsNone() async throws {
        let rig = makeRig()
        defer { rig.connection.invalidate() }
        let data: Data = await withCheckedContinuation { continuation in
            rig.helper().sessionStatus { continuation.resume(returning: $0) }
        }
        let status = try #require(SessionStatus.decode(data))
        #expect(status.state == .none)
        #expect(status.snapshot == nil)
    }

    @Test func pushesStatusChangesToTheAppsObserver() async throws {
        let rig = makeRig()
        defer { rig.connection.invalidate() }
        // A round trip first, so the helper has accepted the connection.
        _ = await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
            rig.helper().protocolVersion { c.resume(returning: $0) }
        }

        let sent = SessionStatus(
            state: .exited, exitCode: -4, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            certFailure: CertFailure(reason: "self-signed certificate", hash: "pin-sha256:abc")
        )
        rig.delegate.service.observers.broadcast(try #require(sent.encoded()))

        var iterator = rig.observer.statuses.makeAsyncIterator()
        let data = try #require(await iterator.next())
        #expect(SessionStatus.decode(data) == sent)
    }

    @Test func rejectsArgumentsOutsideTheNarrowVerbs() async {
        let rig = makeRig()
        defer { rig.connection.invalidate() }

        // Nothing here may start a session or run `route`.
        let startError: NSError? = await withCheckedContinuation { continuation in
            rig.helper().startSession(
                url: "https://vpn.example.edu", cookie: "x", vpncScript: nil, pinnedCertHash: nil,
                verbose: false, logPath: "/etc/hosts"
            ) { continuation.resume(returning: $0) }
        }
        #expect(startError != nil)

        let routeError: NSError? = await withCheckedContinuation { continuation in
            rig.helper().setDefaultRoute(gatewayIP: "-inet6") { continuation.resume(returning: $0) }
        }
        #expect(routeError != nil)
    }
}
