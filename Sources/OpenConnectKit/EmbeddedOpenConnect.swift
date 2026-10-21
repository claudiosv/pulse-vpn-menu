import COpenConnectShim
import Foundation

public struct OpenConnectStats: Sendable {
    public var txPackets: UInt64
    public var txBytes: UInt64
    public var rxPackets: UInt64
    public var rxBytes: UInt64
}

public struct OpenConnectTunnel: Sendable {
    public var address: String?
    public var netmask: String?
    public var gateway: String?
    public var mtu: Int
}

public struct OpenConnectHandlers: Sendable {
    public var log: @Sendable (_ level: Int, _ line: String) -> Void
    public var stats: @Sendable (OpenConnectStats) -> Void
    public var connected: @Sendable (OpenConnectTunnel) -> Void

    public init(
        log: @escaping @Sendable (Int, String) -> Void = { _, _ in },
        stats: @escaping @Sendable (OpenConnectStats) -> Void = { _ in },
        connected: @escaping @Sendable (OpenConnectTunnel) -> Void = { _ in }
    ) {
        self.log = log
        self.stats = stats
        self.connected = connected
    }
}

/// One libopenconnect session running in-process on its own thread. Needs
/// root to create the utun device, so it belongs in the privileged helper.
/// Callbacks fire on the session thread.
public final class EmbeddedOpenConnect: @unchecked Sendable {
    private let handlers: OpenConnectHandlers
    private var session: OpaquePointer?
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
        reconnectTimeout: Int32 = 30,
        dpdSeconds: Int32 = 5,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        var callbacks = ocshim_callbacks(
            log: { ctx, level, msg in
                let me = Unmanaged<EmbeddedOpenConnect>.fromOpaque(ctx!).takeUnretainedValue()
                me.handlers.log(Int(level), String(cString: msg!))
            },
            stats: { ctx, txP, txB, rxP, rxB in
                let me = Unmanaged<EmbeddedOpenConnect>.fromOpaque(ctx!).takeUnretainedValue()
                me.handlers.stats(OpenConnectStats(txPackets: txP, txBytes: txB, rxPackets: rxP, rxBytes: rxB))
            },
            connected: { ctx, addr, mask, gw, mtu in
                let me = Unmanaged<EmbeddedOpenConnect>.fromOpaque(ctx!).takeUnretainedValue()
                me.handlers.connected(OpenConnectTunnel(
                    address: addr.map { String(cString: $0) },
                    netmask: mask.map { String(cString: $0) },
                    gateway: gw.map { String(cString: $0) },
                    mtu: Int(mtu)))
            })

        // The session thread holds a strong ref to self, so the callback
        // context stays valid until ocshim_run returns.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let created = ocshim_new(&callbacks, ctx) else {
            onExit(-ENOMEM)
            return
        }
        self.session = created
        nonisolated(unsafe) let session = created

        let thread = Thread { [self] in
            let rc = ocshim_run(session, url, cookie, vpncScript, reconnectTimeout, dpdSeconds)
            self.session = nil
            ocshim_free(session)
            onExit(rc)
        }
        thread.name = "openconnect-session"
        self.thread = thread
        thread.start()
    }

    // ponytail: no lock around `session`; a call racing session teardown can
    // touch freed memory. Guard with a mutex when this leaves prototype stage.
    public func cancel() { session.map(ocshim_cancel) }
    public func requestStats() { session.map(ocshim_request_stats) }
    public func requestReconnect() { session.map(ocshim_request_reconnect) }
}
