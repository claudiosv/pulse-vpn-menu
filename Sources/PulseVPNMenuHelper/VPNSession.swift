import Foundation
import OpenConnectKit
import PulseVPNHelperProtocol

/// The single in-process libopenconnect session this helper hosts, plus the
/// `SessionStatus` it reports. Everything the app used to learn from a
/// subprocess (pid, exit code, log file) comes from here instead.
final class VPNSession: @unchecked Sendable {
    /// Called (outside any lock) whenever the status the app would see has
    /// changed — start, exit, or a link/ESP/tunnel change. Not for counters.
    var onChange: (@Sendable () -> Void)?

    /// How often the counters are refreshed while a session runs. The app
    /// reads them at its own pace; this just keeps them recent.
    private static let sampleInterval: TimeInterval = 1

    private struct Core {
        var state: SessionStatus.State = .none
        var exitCode: Int32 = 0
        var startedAt: Date?
        var certFailure: CertFailure?
    }

    private let lock = NSLock()
    private var oc: EmbeddedOpenConnect?
    private var core = Core()
    private var sampler: DispatchSourceTimer?

    /// The running session, if any, for sending commands to.
    var running: EmbeddedOpenConnect? {
        lock.withLock { core.state == .running ? oc : nil }
    }

    func currentStatus() -> SessionStatus {
        let (core, session) = lock.withLock { (self.core, self.oc) }
        return SessionStatus(
            state: core.state,
            exitCode: core.exitCode,
            startedAt: core.startedAt,
            certFailure: core.certFailure,
            snapshot: core.state == .running ? session?.snapshot().map(Self.wire) : nil
        )
    }

    func start(
        url: String,
        cookie: String,
        vpncScript: String?,
        pinnedCertHash: String?,
        verbose: Bool,
        logPath: String
    ) throws {
        let (session, queue, writer, logFile): (EmbeddedOpenConnect, DispatchQueue, TimestampingLogWriter, CappedLogFile) = try lock.withLock {
            guard core.state != .running else { throw HelperError("A VPN session is already running") }
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

            core = Core(state: .running, startedAt: Date())
            let session = EmbeddedOpenConnect(handlers: OpenConnectHandlers(
                log: { _, line in
                    queue.async { writer.consume(Data(line.utf8)) }
                },
                certRejected: { [weak self] reason, hash in
                    self?.lock.withLock {
                        self?.core.certFailure = CertFailure(reason: reason, hash: hash)
                    }
                },
                stateChanged: { [weak self] in
                    self?.onChange?()
                }
            ))
            oc = session
            return (session, queue, writer, logFile)
        }

        onChange?()
        startSampling()

        // Outside the lock: if the session fails to start, the exit handler
        // below runs synchronously and takes it again.
        session.start(
            url: url,
            cookie: cookie,
            vpncScript: vpncScript,
            pinnedCert: pinnedCertHash,
            verbose: verbose
        ) { [weak self] rc in
            queue.async {
                writer.flush()
                logFile.close()
            }
            self?.stopSampling()
            self?.lock.withLock {
                self?.core.state = .exited
                self?.core.exitCode = rc
                self?.oc = nil
            }
            self?.onChange?()
        }
    }

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

    private static func wire(_ s: OpenConnectSnapshot) -> SessionSnapshot {
        SessionSnapshot(
            linkState: .init(s.linkState),
            espEstablished: s.espEstablished,
            dropCount: Int(s.dropCount),
            statsSequence: Int(s.statsSequence),
            sampledAt: Date(timeIntervalSince1970: s.sampledAt),
            txPackets: s.txPackets, txBytes: s.txBytes,
            rxPackets: s.rxPackets, rxBytes: s.rxBytes,
            interfaceName: s.interfaceName, address: s.address
        )
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
