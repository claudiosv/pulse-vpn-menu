import COpenConnectShim
import Foundation

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
    /// When the login expires (seconds since 1970), if the server said.
    public var expiresAt: Double?
    public var txPackets: UInt64
    public var txBytes: UInt64
    public var rxPackets: UInt64
    public var rxBytes: UInt64
    /// The tunnel's IPv4 address, once up.
    public var address: String?

    init(_ c: ocshim_snapshot) {
        linkState = LinkState(rawValue: Int32(c.link_state)) ?? .connecting
        espEstablished = c.esp_established != 0
        dropCount = c.drop_count
        statsSequence = c.stats_seq
        sampledAt = c.sampled_at
        expiresAt = c.expires_at > 0 ? c.expires_at : nil
        txPackets = c.tx_pkts
        txBytes = c.tx_bytes
        rxPackets = c.rx_pkts
        rxBytes = c.rx_bytes
        var c = c
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
    /// The server accepted the session and assigned addresses. Apply them,
    /// then return a datagram fd carrying the tunnel's packets with utun
    /// framing (4-byte address family in network byte order, then one IP
    /// packet), or a negative errno to abort. May block; the fd stays owned
    /// by the caller, who closes it after the session exits.
    public var configureTunnel: @Sendable (OpenConnectNetworkConfig) -> Int32
    /// Certificate failed validation and didn't match the pin; `hash` is the
    /// `pin-sha256:...` value to pass as `pinnedCert` to trust it.
    public var certRejected: @Sendable (_ reason: String, _ hash: String?) -> Void
    /// A certificate failed libopenconnect's own validation: does the system
    /// trust this chain (DER, leaf first) for this host name? Return true to
    /// accept the connection. Called on the session thread.
    public var trustChain: @Sendable (_ chain: [Data], _ host: String?) -> Bool
    /// Link state, ESP flag, drop count or tunnel identity changed (not the
    /// counters). Fires on a libopenconnect thread; read `snapshot()`.
    public var stateChanged: @Sendable () -> Void

    public init(
        log: @escaping @Sendable (Int, String) -> Void = { _, _ in },
        configureTunnel: @escaping @Sendable (OpenConnectNetworkConfig) -> Int32 = { _ in -ENOTSUP },
        certRejected: @escaping @Sendable (String, String?) -> Void = { _, _ in },
        trustChain: @escaping @Sendable ([Data], String?) -> Bool = { _, _ in false },
        stateChanged: @escaping @Sendable () -> Void = {}
    ) {
        self.log = log
        self.configureTunnel = configureTunnel
        self.certRejected = certRejected
        self.trustChain = trustChain
        self.stateChanged = stateChanged
    }
}

/// One libopenconnect session running in-process on its own thread. It
/// creates no network interface and runs no script: `configureTunnel` supplies
/// the packet fd, so it works inside a sandboxed Network Extension.
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
            configure: { ctx, config in
                let me = Unmanaged<EmbeddedOpenConnect>.fromOpaque(ctx!).takeUnretainedValue()
                return me.handlers.configureTunnel(OpenConnectNetworkConfig(config!.pointee))
            },
            cert_rejected: { ctx, reason, hash in
                let me = Unmanaged<EmbeddedOpenConnect>.fromOpaque(ctx!).takeUnretainedValue()
                me.handlers.certRejected(String(cString: reason!), hash.map { String(cString: $0) })
            },
            trust_chain: { ctx, ders, lens, count, host in
                let me = Unmanaged<EmbeddedOpenConnect>.fromOpaque(ctx!).takeUnretainedValue()
                var chain: [Data] = []
                for index in 0..<Int(count) {
                    if let der = ders?[index] { chain.append(Data(bytes: der, count: Int(lens![index]))) }
                }
                return me.handlers.trustChain(chain, host.map { String(cString: $0) }) ? 1 : 0
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
            let rc = ocshim_run(session, url, cookie, pinnedCert,
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
