import Foundation
import OpenConnectKit
import PulseVPNHelperProtocol

/// The single in-process libopenconnect session this helper hosts, plus the
/// state `sessionStatus` reports. Everything the app used to learn from a
/// subprocess (pid, exit code, log file) comes from here instead.
final class VPNSession: @unchecked Sendable {
    enum State: Int32 {
        case none = 0, running = 1, exited = 2
    }

    struct Status {
        var state: State
        var exitCode: Int32
        var startedAt: Double
        var certFailureReason: String?
        var certHash: String?
    }

    private let lock = NSLock()
    private var oc: EmbeddedOpenConnect?
    private var status = Status(state: .none, exitCode: 0, startedAt: 0)

    func currentStatus() -> Status {
        lock.withLock { status }
    }

    /// JSON-encoded `SessionSnapshot` of the running session, if any.
    func snapshotData() -> Data? {
        running?.snapshot().flatMap(Self.encode)
    }

    /// Like `snapshotData()` but refreshes the traffic counters first.
    func pollStatsData() -> Data? {
        running?.pollStats().flatMap { Self.encode($0.snapshot) }
    }

    private static func encode(_ s: OpenConnectSnapshot) -> Data? {
        let wire = SessionSnapshot(
            linkState: .init(s.linkState),
            espEstablished: s.espEstablished,
            dropCount: Int(s.dropCount),
            statsSequence: Int(s.statsSequence),
            txPackets: s.txPackets, txBytes: s.txBytes,
            rxPackets: s.rxPackets, rxBytes: s.rxBytes
        )
        return try? JSONEncoder().encode(wire)
    }

    /// The running session, if any, for sending commands to.
    var running: EmbeddedOpenConnect? {
        lock.withLock { status.state == .running ? oc : nil }
    }

    func start(
        url: String,
        cookie: String,
        vpncScript: String?,
        pinnedCertHash: String?,
        logPath: String
    ) throws {
        let (session, queue, writer, logFile): (EmbeddedOpenConnect, DispatchQueue, TimestampingLogWriter, CappedLogFile) = try lock.withLock {
            guard status.state != .running else { throw HelperError("A VPN session is already running") }
            guard let logFile = CappedLogFile(path: logPath) else {
                throw HelperError("Could not open \(logPath) for writing")
            }

            // launchd gives daemons a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin)
            // that doesn't include Homebrew — libopenconnect runs the vpnc-script
            // (`sh -c "vpn-slice ..."`) with this process's environment, so
            // without this the script fails with "command not found" even though
            // the tunnel itself comes up.
            setenv("PATH", "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin", 1)

            // All writes to the log go through one queue (log lines arrive on the
            // session thread, flush/close on exit).
            let queue = DispatchQueue(label: "com.claudiosv.pulse-vpn-menu.helper.logwriter")
            let writer = TimestampingLogWriter(logFile: logFile)

            status = Status(state: .running, exitCode: 0, startedAt: Date().timeIntervalSince1970)
            let session = EmbeddedOpenConnect(handlers: OpenConnectHandlers(
                log: { _, line in
                    queue.async { writer.consume(Data(line.utf8)) }
                },
                certRejected: { [weak self] reason, hash in
                    self?.lock.withLock {
                        self?.status.certFailureReason = reason
                        self?.status.certHash = hash
                    }
                }
            ))
            oc = session
            return (session, queue, writer, logFile)
        }

        // Outside the lock: if the session fails to start, the exit handler
        // below runs synchronously and takes it again.
        session.start(
            url: url,
            cookie: cookie,
            vpncScript: vpncScript,
            pinnedCert: pinnedCertHash
        ) { [weak self] rc in
            queue.async {
                writer.flush()
                logFile.close()
            }
            self?.lock.withLock {
                self?.status.state = .exited
                self?.status.exitCode = rc
                self?.oc = nil
            }
        }
    }
}

struct HelperError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension SessionSnapshot.LinkState {
    init(_ s: OpenConnectSnapshot.LinkState) {
        switch s {
        case .connecting: self = .connecting
        case .up: self = .up
        case .reconnecting: self = .reconnecting
        }
    }
}
