import COpenConnectShim
import Foundation

public struct OpenConnectTunnel: Sendable {
    public var address: String?
    public var netmask: String?
    public var gateway: String?
    public var mtu: Int
}

public struct OpenConnectHandlers: Sendable {
    /// One line of libopenconnect output, including the periodic status lines
    /// (`Configured as ...`, `RX: ... TX: ...`) produced by `requestStats()`.
    public var log: @Sendable (_ level: Int, _ line: String) -> Void
    public var connected: @Sendable (OpenConnectTunnel) -> Void
    /// Certificate failed validation and didn't match the pin; `hash` is the
    /// `pin-sha256:...` value to pass as `pinnedCert` to trust it.
    public var certRejected: @Sendable (_ reason: String, _ hash: String?) -> Void

    public init(
        log: @escaping @Sendable (Int, String) -> Void = { _, _ in },
        connected: @escaping @Sendable (OpenConnectTunnel) -> Void = { _ in },
        certRejected: @escaping @Sendable (String, String?) -> Void = { _, _ in }
    ) {
        self.log = log
        self.connected = connected
        self.certRejected = certRejected
    }
}

/// One libopenconnect session running in-process on its own thread. Needs
/// root to create the utun device, so it belongs in the privileged helper.
/// Callbacks fire on the session thread.
public final class EmbeddedOpenConnect: @unchecked Sendable {
    private let handlers: OpenConnectHandlers
    private let lock = NSLock()
    private var session: OpaquePointer?   // guarded by `lock`
    private var thread: Thread?

    public init(handlers: OpenConnectHandlers) {
        self.handlers = handlers
    }

    /// Starts the session; `onExit` gets libopenconnect's result code
    /// (-EINTR after `cancel()`, -EPERM if the cookie was rejected, ...).
    public func start(
        url: String,
        cookie: String,
        vpncScript: String?,
        pinnedCert: String? = nil,
        reconnectTimeout: Int32 = 30,
        dpdSeconds: Int32 = 5,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        var callbacks = ocshim_callbacks(
            log: { ctx, level, msg in
                let me = Unmanaged<EmbeddedOpenConnect>.fromOpaque(ctx!).takeUnretainedValue()
                me.handlers.log(Int(level), String(cString: msg!))
            },
            connected: { ctx, addr, mask, gw, mtu in
                let me = Unmanaged<EmbeddedOpenConnect>.fromOpaque(ctx!).takeUnretainedValue()
                me.handlers.connected(OpenConnectTunnel(
                    address: addr.map { String(cString: $0) },
                    netmask: mask.map { String(cString: $0) },
                    gateway: gw.map { String(cString: $0) },
                    mtu: Int(mtu)))
            },
            cert_rejected: { ctx, reason, hash in
                let me = Unmanaged<EmbeddedOpenConnect>.fromOpaque(ctx!).takeUnretainedValue()
                me.handlers.certRejected(String(cString: reason!), hash.map { String(cString: $0) })
            })

        // The session thread holds a strong ref to self, so the callback
        // context stays valid until ocshim_run returns.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let created = ocshim_new(&callbacks, ctx) else {
            onExit(-ENOMEM)
            return
        }
        lock.withLock { self.session = created }
        nonisolated(unsafe) let session = created

        let thread = Thread { [self] in
            let rc = ocshim_run(session, url, cookie, vpncScript, pinnedCert,
                                reconnectTimeout, dpdSeconds)
            // Taking the lock waits out any in-flight cancel()/requestStats().
            self.lock.withLock { self.session = nil }
            ocshim_free(session)
            onExit(rc)
        }
        thread.name = "openconnect-session"
        self.thread = thread
        thread.start()
    }

    public func cancel() { withSession(ocshim_cancel) }
    public func requestStats() { withSession(ocshim_request_stats) }
    public func requestReconnect() { withSession(ocshim_request_reconnect) }

    private func withSession(_ body: (OpaquePointer) -> Void) {
        lock.withLock { if let session { body(session) } }
    }
}
