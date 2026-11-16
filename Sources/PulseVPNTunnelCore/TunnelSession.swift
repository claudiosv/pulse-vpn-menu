import Darwin
import Foundation
import OpenConnectKit
import PulseVPNTunnelProtocol

/// The single in-process libopenconnect session a provider hosts, plus the
/// `SessionStatus` and log it reports to the app.
public final class TunnelSession: @unchecked Sendable {
    /// Called (outside any lock) whenever the status the app would see has
    /// changed — start, exit, or a link/ESP/tunnel change. Not for counters.
    public var onChange: (@Sendable () -> Void)?

    public let log = LogRing()

    /// How often the counters are refreshed while a session runs. The app
    /// reads them at its own pace; this just keeps them recent.
    private static let sampleInterval: TimeInterval = 1

    private struct Core {
        var state: SessionStatus.State = .none
        var exitCode: Int32 = 0
        var startedAt: Date?
        var certFailure: CertFailure?
        var interfaceName: String?
        var dnsServers: [String]?
        var dnsDomains: [String]?
    }

    private let lock = NSLock()
    private var oc: EmbeddedOpenConnect?
    private var core = Core()
    private var sampler: DispatchSourceTimer?

    public init() {}

    /// The running session, if any, for sending commands to.
    private var running: EmbeddedOpenConnect? {
        lock.withLock { core.state == .running ? oc : nil }
    }

    public var isRunning: Bool { running != nil }

    public func status() -> SessionStatus {
        let (core, session) = lock.withLock { (self.core, self.oc) }
        return SessionStatus(
            state: core.state,
            exitCode: core.exitCode,
            startedAt: core.startedAt,
            certFailure: core.certFailure,
            snapshot: core.state == .running
                ? session?.snapshot().map {
                    Self.wire($0, interfaceName: core.interfaceName,
                              dnsServers: core.dnsServers, dnsDomains: core.dnsDomains)
                }
                : nil
        )
    }

    /// Starts the session on its own thread and returns at once.
    ///
    /// - `configureTunnel`: called on the session thread once the server has
    ///   assigned addresses; see `OpenConnectHandlers.configureTunnel`.
    /// - `onExit`: called on the session thread with libopenconnect's result
    ///   after the status has become `exited`.
    public func start(
        url: String,
        cookie: String,
        pinnedCertHash: String?,
        verbose: Bool,
        configureTunnel: @escaping @Sendable (OpenConnectNetworkConfig) -> Int32,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        let log = log
        let session = EmbeddedOpenConnect(handlers: OpenConnectHandlers(
            log: { _, line in log.append(line) },
            configureTunnel: configureTunnel,
            certRejected: { [weak self] reason, hash in
                self?.lock.withLock {
                    self?.core.certFailure = CertFailure(reason: reason, hash: hash)
                }
            },
            stateChanged: { [weak self] in
                self?.onChange?()
            }
        ))
        lock.withLock {
            core = Core(state: .running, startedAt: Date())
            oc = session
        }
        onChange?()
        startSampling()

        session.start(
            url: url,
            cookie: cookie,
            pinnedCert: pinnedCertHash,
            verbose: verbose
        ) { [weak self] rc in
            log.flush()
            self?.finish(exitCode: rc)
            onExit(rc)
        }
    }

    /// Records a session that ended before libopenconnect was ever started
    /// (e.g. there was no login cookie), so the app sees why.
    public func fail(exitCode: Int32, message: String) {
        log.append(message + "\n")
        lock.withLock { core.startedAt = Date() }
        finish(exitCode: exitCode)
    }

    private func finish(exitCode: Int32) {
        stopSampling()
        lock.withLock {
            core.state = .exited
            core.exitCode = exitCode
            oc = nil
        }
        onChange?()
    }

    /// What the provider put in place for the tunnel, which libopenconnect
    /// never sees: the interface the system created, and the DNS servers in
    /// use with the domains they answer for (nil: everything).
    public func setTunnelDetails(interfaceName: String?, dnsServers: [String], dnsDomains: [String]?) {
        lock.withLock {
            core.interfaceName = interfaceName
            core.dnsServers = dnsServers
            core.dnsDomains = dnsDomains
        }
    }

    public func cancel() { running?.cancel() }                      // ~ SIGTERM
    public func requestReconnect() { running?.requestReconnect() }  // ~ SIGUSR2

    // MARK: - Counter sampling

    private func startSampling() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.sampleInterval, repeating: Self.sampleInterval)
        timer.setEventHandler { [weak self] in self?.running?.requestStats() }
        lock.withLock {
            sampler?.cancel()
            sampler = timer
        }
        timer.resume()
    }

    private func stopSampling() {
        lock.withLock {
            sampler?.cancel()
            sampler = nil
        }
    }

    // MARK: - Wire format

    private static func wire(
        _ s: OpenConnectSnapshot, interfaceName: String?, dnsServers: [String]?, dnsDomains: [String]?
    ) -> SessionSnapshot {
        let linkState: SessionSnapshot.LinkState
        switch s.linkState {
        case .connecting: linkState = .connecting
        case .up: linkState = .up
        case .reconnecting: linkState = .reconnecting
        }
        return SessionSnapshot(
            linkState: linkState,
            espEstablished: s.espEstablished,
            dropCount: Int(s.dropCount),
            statsSequence: Int(s.statsSequence),
            sampledAt: Date(timeIntervalSince1970: s.sampledAt),
            txPackets: s.txPackets, txBytes: s.txBytes,
            rxPackets: s.rxPackets, rxBytes: s.rxBytes,
            interfaceName: interfaceName, address: s.address,
            dnsServers: dnsServers, dnsDomains: dnsDomains
        )
    }
}

/// The interface that carries `address` (e.g. `utun6`), found by scanning
/// the system's interfaces.
public func interfaceName(forIPv4 address: String) -> String? {
    var wanted = in_addr()
    guard inet_pton(AF_INET, address, &wanted) == 1 else { return nil }
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return nil }
    defer { freeifaddrs(list) }
    var cursor = list
    while let entry = cursor {
        defer { cursor = entry.pointee.ifa_next }
        guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        let found = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        if found == wanted.s_addr {
            return String(cString: entry.pointee.ifa_name)
        }
    }
    return nil
}
