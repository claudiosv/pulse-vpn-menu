import COpenConnectShim
import Foundation

public struct OpenConnectTunnel: Sendable {
    public var address: String?
    public var netmask: String?
    public var gateway: String?
    public var mtu: Int
}

/// Typed session state, read directly from libopenconnect (no log parsing).
public struct OpenConnectSnapshot: Sendable, Equatable {
    public enum LinkState: Int32, Sendable {
        case connecting = 0
        case up = 1
        case reconnecting = 2
    }

    public var linkState: LinkState
    /// The ESP (UDP) data channel has been negotiated. Cleared by `requestReconnect()`.
    public var espEstablished: Bool
    /// Number of times the link dropped and libopenconnect started retrying.
    public var dropCount: UInt32
    /// Increments each time the counters below are refreshed.
    public var statsSequence: UInt64
    /// When the counters were last refreshed (seconds since 1970).
    public var sampledAt: Double
    public var txPackets: UInt64
    public var txBytes: UInt64
    public var rxPackets: UInt64
    public var rxBytes: UInt64
    /// The tunnel's interface name (e.g. `utun6`) and IPv4 address, once up.
    public var interfaceName: String?
    public var address: String?

    init(_ c: ocshim_snapshot) {
        linkState = LinkState(rawValue: Int32(c.link_state)) ?? .connecting
        espEstablished = c.esp_established != 0
        dropCount = c.drop_count
        statsSequence = c.stats_seq
        sampledAt = c.sampled_at
        txPackets = c.tx_pkts
        txBytes = c.tx_bytes
        rxPackets = c.rx_pkts
        rxBytes = c.rx_bytes
        var c = c
        interfaceName = Self.string(&c.ifname)
        address = Self.string(&c.address)
    }

    /// A fixed-size C `char[]` (imported as a tuple), or nil if empty.
    private static func string<T>(_ buffer: inout T) -> String? {
        withUnsafePointer(to: &buffer) {
            let s = String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            return s.isEmpty ? nil : s
        }
    }
}

public struct OpenConnectHandlers: Sendable {
    /// One line of libopenconnect output, for display only.
    public var log: @Sendable (_ level: Int, _ line: String) -> Void
    public var connected: @Sendable (OpenConnectTunnel) -> Void
    /// Certificate failed validation and didn't match the pin; `hash` is the
    /// `pin-sha256:...` value to pass as `pinnedCert` to trust it.
    public var certRejected: @Sendable (_ reason: String, _ hash: String?) -> Void
    /// Link state, ESP flag, drop count or tunnel identity changed (not the
    /// counters). Fires on a libopenconnect thread; read `snapshot()`.
    public var stateChanged: @Sendable () -> Void

    public init(
        log: @escaping @Sendable (Int, String) -> Void = { _, _ in },
        connected: @escaping @Sendable (OpenConnectTunnel) -> Void = { _ in },
        certRejected: @escaping @Sendable (String, String?) -> Void = { _, _ in },
        stateChanged: @escaping @Sendable () -> Void = {}
    ) {
        self.log = log
        self.connected = connected
        self.certRejected = certRejected
        self.stateChanged = stateChanged
    }
}

/// One libopenconnect session running in-process on its own thread. Needs
/// root to create the utun device, so it belongs in the privileged helper.
/// Callbacks fire on the session thread.
public final class EmbeddedOpenConnect: @unchecked Sendable {
    private let handlers: OpenConnectHandlers
    /// Recursive on purpose: `requestReconnect()` calls into C while holding
    /// it, and the shim reports the resulting state change straight back
    /// through `handlers.stateChanged` on the same thread, whose handler reads
    /// `snapshot()` — a plain lock would deadlock there.
    private let lock = NSRecursiveLock()
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
        verbose: Bool = false,
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
            },
            state_changed: { ctx in
                let me = Unmanaged<EmbeddedOpenConnect>.fromOpaque(ctx!).takeUnretainedValue()
                me.handlers.stateChanged()
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
                                reconnectTimeout, dpdSeconds, verbose ? 1 : 0)
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
    public func requestReconnect() { withSession(ocshim_request_reconnect) }

    /// Refreshes the counters; returns at once. The new sample shows up in
    /// `snapshot()` (higher `statsSequence`) shortly after.
    public func requestStats() { withSession(ocshim_request_stats) }

    /// Latest state without asking for new counters; nil if no session.
    public func snapshot() -> OpenConnectSnapshot? {
        withSession { session in
            var c = ocshim_snapshot()
            ocshim_get_snapshot(session, &c)
            return OpenConnectSnapshot(c)
        }
    }

    @discardableResult
    private func withSession<T>(_ body: (OpaquePointer) -> T) -> T? {
        lock.withLock { session.map(body) }
    }
}
