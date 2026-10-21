import Darwin
import Foundation
import Testing
@testable import OpenConnectKit

/// A TCP listener that accepts connections (via the backlog) and never says
/// a word, so a session's TLS handshake sits there until it's cancelled.
private final class SilentServer {
    let port: UInt16
    private let fd: Int32

    init() {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(listener, $0, length)
                listen(listener, 4)
                getsockname(listener, $0, &length)
            }
        }
        fd = listener
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { close(fd) }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite struct EmbeddedOpenConnectTests {
    /// `requestReconnect()` makes the shim report a state change from inside
    /// the call; the handler reads `snapshot()`. That used to deadlock on the
    /// wrapper's own lock. Needs a live session object, so it runs against a
    /// server that never answers.
    @Test func reconnectRequestDoesNotDeadlockAndCancelEndsTheSession() {
        let server = SilentServer()
        let changes = Counter()
        let exited = DispatchSemaphore(value: 0)
        let sawSnapshot = Counter()

        nonisolated(unsafe) var oc: EmbeddedOpenConnect!
        oc = EmbeddedOpenConnect(handlers: OpenConnectHandlers(stateChanged: {
            changes.increment()
            if oc.snapshot() != nil { sawSnapshot.increment() }   // re-enters the wrapper
        }))
        oc.start(url: "https://127.0.0.1:\(server.port)/", cookie: "x", vpncScript: nil) { _ in
            exited.signal()
        }
        Thread.sleep(forTimeInterval: 0.3)   // let the session thread set up its command pipe

        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            oc.requestReconnect()
            returned.signal()
        }
        #expect(returned.wait(timeout: .now() + 3) == .success, "requestReconnect() hung")
        #expect(changes.count >= 1)
        #expect(sawSnapshot.count >= 1)

        oc.cancel()
        #expect(exited.wait(timeout: .now() + 10) == .success, "session did not end after cancel()")
    }
}
