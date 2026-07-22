import Foundation
import Darwin

enum ConnectExitOutcome {
    case up
    case rejectedCookie
    case failed(Int32)
}

struct ConnectAttemptResult {
    let outcome: ConnectExitOutcome
    /// The DSID actually used for this attempt (reused from the profile or
    /// freshly fetched via the browser), so the caller can persist it.
    let dsidUsed: String?
}

enum ConnectError: Error, CustomStringConvertible {
    case openconnectNotFound
    case tunnelTimeout
    case pidNotResolved

    var description: String {
        switch self {
        case .openconnectNotFound: return "Could not locate the openconnect binary."
        case .tunnelTimeout: return "Could not find a valid VPN interface with an IPv4 address."
        case .pidNotResolved: return "openconnect did not report its PID in time."
        }
    }
}

/// Mirrors `launcher.py`'s `OpenconnectPulseLauncher`: authenticates (via
/// `DSIDAuthenticator`), launches openconnect as root (via
/// `PrivilegedRunner`), waits for the tunnel interface to come up, manages
/// routes (`RouteManager`), and delivers signals for stop/reconnect/stats.
@MainActor
final class OpenConnectController: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var connectedProfileID: UUID?

    let stats = StatsHistory()
    let logStore: LogStore

    private let privileged = PrivilegedRunner()
    private lazy var routeManager = RouteManager(privileged: privileged)
    private let authenticator = DSIDAuthenticator()

    /// Absolute path — required (not just cleaner) so the sudo-mode
    /// NOPASSWD sudoers rule, which matches an exact resolved path,
    /// matches unambiguously regardless of `sudo`'s own PATH resolution.
    private static let killPath = "/bin/kill"

    private var statsTimerTask: Task<Void, Never>?
    private var runtimeState: RuntimeState?
    /// Held only when launched via the sudo path (see `PrivilegedRunner`):
    /// a live handle whose `isRunning`/`terminationStatus` track the real
    /// openconnect process directly, no pidfile/exitfile polling needed.
    private var managedProcess: Process?
    private var hasAttemptedSudoersSetup = false

    static let tunnelTimeout: TimeInterval = 30
    static let statsInterval: TimeInterval = 5

    init(logStore: LogStore) {
        self.logStore = logStore
        logStore.onLine = { [weak self] line in
            self?.stats.ingest(line)
        }

        if let state = RuntimeState.load(), Self.isProcessAlive(pid: state.pid, expectedName: "openconnect") {
            self.runtimeState = state
            self.connectedProfileID = state.profileID
            // Every relaunch while already connected — not just the
            // crash/pid-file-recovery case below — needs this too, or the
            // stats timer (and thus `kill -USR1`) never resumes and no
            // more RX/TX stats ever show up in the log.
            startStatsTimer(pid: state.pid)
        } else if let recovered = Self.recoverStateFromPidFile() {
            // The app was killed/crashed/relaunched without a clean
            // disconnect, but openconnect itself is still running (it's a
            // detached, privileged process independent of our own
            // lifetime) — reattach instead of showing "disconnected" while
            // a real tunnel is up underneath us.
            recovered.save()
            self.runtimeState = recovered
            self.connectedProfileID = recovered.profileID
            logStore.append("Reattached to an already-running openconnect process (pid \(recovered.pid)).\n")
            startStatsTimer(pid: recovered.pid)
        } else {
            RuntimeState.clear()
        }
    }

    /// Falls back to the stable PID file (as opposed to the full
    /// `RuntimeState` blob, which may be missing or stale if the app died
    /// before writing it) to rediscover an already-running openconnect
    /// process. Profile identity, original gateway, and hostname are
    /// unknowable in this case; `noDefaultRoute` defaults to `true` so a
    /// later disconnect doesn't guess at route changes it has no record of
    /// — openconnect/vpnc-script clean up their own routes on SIGTERM
    /// regardless.
    private static func recoverStateFromPidFile() -> RuntimeState? {
        guard let text = try? String(contentsOf: AppPaths.openconnectPidFile, encoding: .utf8) else { return nil }
        guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        guard isProcessAlive(pid: pid, expectedName: "openconnect") else { return nil }
        return RuntimeState(
            pid: pid,
            profileID: nil,
            startedAt: Date(),
            vpnGatewayIP: NetworkInterfaces.findVPNInterface()?.ip,
            originalGatewayIP: nil,
            hostname: nil,
            noDefaultRoute: true
        )
    }

    // MARK: - Status

    func isConnected() -> Bool {
        guard let state = runtimeState else { return false }
        return Self.isProcessAlive(pid: state.pid, expectedName: "openconnect")
    }

    var connectedInterfaceDescription: String? {
        guard isConnected(), let (name, ip) = NetworkInterfaces.findVPNInterface() else { return nil }
        return "\(name), \(ip)"
    }

    // MARK: - Connect

    /// Authenticate-then-launch-then-retry loop, mirroring `connect()` in
    /// `launcher.py`: on a rejected DSID cookie (exit code 2), clear it and
    /// re-authenticate.
    func connect(profile: ConnectionProfile, store: ConnectionStore) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        if !hasAttemptedSudoersSetup {
            hasAttemptedSudoersSetup = true
            if !SudoersInstaller.isInstalled() {
                do {
                    try await SudoersInstaller.install()
                    logStore.append("Installed a passwordless-sudo rule for VPN commands (openconnect, route, kill) — you won't be prompted for a password on every action anymore.\n")
                } catch {
                    logStore.append("Could not set up passwordless sudo (\(error)); will keep prompting for a password per action.\n")
                }
            }
        }

        var workingProfile = profile
        while true {
            do {
                let result = try await connectOnce(profile: workingProfile)

                if let dsid = result.dsidUsed, workingProfile.lastDSID != dsid {
                    workingProfile.lastDSID = dsid
                    store.updateDSID(profileID: workingProfile.id, dsid: dsid)
                }

                switch result.outcome {
                case .up:
                    connectedProfileID = workingProfile.id
                    return
                case .rejectedCookie:
                    workingProfile.lastDSID = nil
                    store.updateDSID(profileID: workingProfile.id, dsid: nil)
                    logStore.append("openconnect rejected the DSID cookie; re-authenticating.\n")
                    continue
                case .failed(let code):
                    logStore.append("openconnect exited with code \(code) before the tunnel came up.\n")
                    return
                }
            } catch {
                logStore.append("Connect failed: \(error)\n")
                return
            }
        }
    }

    /// Single connect attempt: authenticate if needed, launch openconnect,
    /// wait for the tunnel, set up routes. Mirrors `connect_once()` in
    /// `launcher.py`.
    func connectOnce(profile: ConnectionProfile) async throws -> ConnectAttemptResult {
        let openconnectPath = Self.findOpenConnectPath()
        let hostname = URL(string: profile.vpnURL)?.host
        let originalGatewayIP = NetworkInterfaces.defaultGatewayIP()

        var dsid = profile.lastDSID
        if dsid == nil || dsid?.isEmpty == true {
            dsid = try await authenticator.fetchDSID(vpnURL: profile.vpnURL)
        }
        guard let dsidValue = dsid, !dsidValue.isEmpty else {
            throw ConnectError.pidNotResolved
        }

        try AppPaths.prepareForNewConnection()
        logStore.resetForNewConnection()
        stats.clear()

        var argv = [openconnectPath]
        if let script = profile.script, !script.isEmpty {
            argv.append(contentsOf: ["-s", script])
        }
        argv.append(contentsOf: [
            // "-vvvv",
            "--reconnect-timeout", "30",
            "--force-dpd", "5",
            "-C", dsidValue,
            "--protocol=pulse",
            profile.vpnURL,
        ])

        let pid: Int32
        var exitFile: URL?

        if privileged.sudoAvailable {
            let process = try privileged.launchOpenConnectViaSudo(argv: argv, logFile: AppPaths.currentLogFile)
            managedProcess = process
            // `sudo`'s own PID is NOT openconnect's PID: this build of sudo
            // forks a child and waits for it rather than exec'ing in place
            // (confirmed empirically — `ps -o pid,ppid,comm` showed
            // sudo and openconnect as distinct processes with a real
            // parent/child relationship). Using sudo's PID for
            // RuntimeState/isConnected/signal-delivery would check or
            // signal the wrong process entirely (the name check against
            // "openconnect" would simply fail forever). `process.isRunning`
            // /`terminationStatus` still correctly track the connection's
            // lifetime, though — sudo waits for and relays its child's
            // exit status as its own.
            if let realPid = try await Self.waitForChildPid(ofParent: process.processIdentifier, named: "openconnect") {
                pid = realPid
            } else if !process.isRunning {
                // A rejected cookie fails near-instantly (no real network
                // round trip needed) — openconnect can exit before a single
                // `ps` poll ever observes it alive, so its child PID is
                // never found. Nothing to track anymore in that case; use
                // sudo's relayed exit status directly instead of treating
                // an already-finished attempt as a hard failure (which
                // would skip the rejected-cookie retry entirely).
                let exitCode = process.terminationStatus
                runtimeState = nil
                RuntimeState.clear()
                if exitCode == 2 {
                    return ConnectAttemptResult(outcome: .rejectedCookie, dsidUsed: dsidValue)
                }
                return ConnectAttemptResult(outcome: .failed(exitCode), dsidUsed: dsidValue)
            } else {
                throw ConnectError.pidNotResolved
            }
        } else {
            managedProcess = nil
            let newExitFile = AppPaths.newExitFile()
            FileManager.default.createFile(atPath: newExitFile.path, contents: nil, attributes: [.posixPermissions: 0o666])
            exitFile = newExitFile

            try await privileged.runOpenConnectBackground(
                argv: argv,
                logFile: AppPaths.currentLogFile,
                pidFile: AppPaths.openconnectPidFile,
                exitFile: newExitFile
            )

            guard let resolvedPid = try await waitForPID() else {
                throw ConnectError.pidNotResolved
            }
            pid = resolvedPid
        }
        defer {
            if let exitFile { try? FileManager.default.removeItem(at: exitFile) }
        }

        // Keep the PID file current regardless of which launch mechanism
        // was used, so crash-recovery (`recoverStateFromPidFile`) works
        // uniformly whether this connection was sudo- or osascript-managed.
        try? String(pid).write(to: AppPaths.openconnectPidFile, atomically: true, encoding: .utf8)

        var state = RuntimeState(
            pid: pid,
            profileID: profile.id,
            startedAt: Date(),
            vpnGatewayIP: nil,
            originalGatewayIP: originalGatewayIP,
            hostname: hostname,
            noDefaultRoute: profile.noDefaultRoute
        )
        state.save()
        runtimeState = state

        let deadline = Date().addingTimeInterval(Self.tunnelTimeout)
        while Date() < deadline {
            let exitCode: Int32? = if let process = managedProcess {
                process.isRunning ? nil : process.terminationStatus
            } else {
                exitFile.flatMap { readExitCodeIfPresent(at: $0) }
            }
            if let exitCode {
                runtimeState = nil
                RuntimeState.clear()
                if exitCode == 2 {
                    return ConnectAttemptResult(outcome: .rejectedCookie, dsidUsed: dsidValue)
                }
                return ConnectAttemptResult(outcome: .failed(exitCode), dsidUsed: dsidValue)
            }
            if let (_, ip) = NetworkInterfaces.findVPNInterface() {
                state.vpnGatewayIP = ip
                state.save()
                runtimeState = state

                if !profile.noDefaultRoute {
                    try await routeManager.setDefaultRoute(gatewayIP: ip)
                }
                if let post = profile.post, !post.isEmpty {
                    runPostCommand(post)
                }
                startStatsTimer(pid: pid)
                return ConnectAttemptResult(outcome: .up, dsidUsed: dsidValue)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ConnectError.tunnelTimeout
    }

    // MARK: - Disconnect / reconnect

    func disconnect() async {
        guard let state = runtimeState else { return }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        stopStatsTimer()

        do {
            try await privileged.run([Self.killPath, "-TERM", String(state.pid)])
            logStore.append("Sent SIGTERM to openconnect pid: \(state.pid)\n")
        } catch {
            logStore.append("Failed to send SIGTERM: \(error)\n")
        }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !Self.isProcessAlive(pid: state.pid, expectedName: "openconnect") { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        do {
            try await routeManager.cleanupAfterDisconnect(
                vpnGatewayIP: state.vpnGatewayIP,
                hostname: state.hostname,
                noDefaultRoute: state.noDefaultRoute,
                originalGatewayIP: state.originalGatewayIP
            )
        } catch {
            logStore.append("Route cleanup failed: \(error)\n")
        }

        runtimeState = nil
        RuntimeState.clear()
        connectedProfileID = nil
        managedProcess = nil
    }

    func reconnect() async throws {
        guard let state = runtimeState else { return }
        try await privileged.run([Self.killPath, "-USR2", String(state.pid)])
        logStore.append("Sent SIGUSR2 to openconnect; reconnecting.\n")
    }

    // MARK: - Stats timer

    private func startStatsTimer(pid: Int32) {
        stopStatsTimer()
        statsTimerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.statsInterval * 1_000_000_000))
                if Task.isCancelled { break }
                guard self.isConnected() else { break }
                try? await self.sendStatsSignal(pid: pid)
            }
        }
    }

    private func stopStatsTimer() {
        statsTimerTask?.cancel()
        statsTimerTask = nil
    }

    private func sendStatsSignal(pid: Int32) async throws {
        try await privileged.run([Self.killPath, "-USR1", String(pid)])
    }

    private func runPostCommand(_ post: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: post)
        try? process.run()
    }

    // MARK: - PID / exit-code polling

    private func waitForPID() async throws -> Int32? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let text = try? String(contentsOf: AppPaths.openconnectPidFile, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = Int32(trimmed) {
                    return pid
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func readExitCodeIfPresent(at exitFile: URL) -> Int32? {
        guard let text = try? String(contentsOf: exitFile, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Int32(trimmed)
    }

    // MARK: - Static helpers

    /// Polls `ps` for a child of `parentPid` named `name` — used to find
    /// openconnect's real PID underneath the `sudo` process that launched
    /// it, since sudo forks rather than exec'ing in place on this system.
    nonisolated private static func waitForChildPid(ofParent parentPid: Int32, named name: String) async throws -> Int32? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let child = childPid(ofParent: parentPid, named: name) {
                return child
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    nonisolated private static func childPid(ofParent parentPid: Int32, named name: String) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid=,ppid=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let childPid = Int32(fields[0]),
                  let ppid = Int32(fields[1]),
                  ppid == parentPid else { continue }
            let comm = (String(fields[2...].joined(separator: " ")) as NSString).lastPathComponent
            if comm == name {
                return childPid
            }
        }
        return nil
    }

    nonisolated static func findOpenConnectPath() -> String {
        if let inPath = findExecutableInPath("openconnect") {
            return inPath
        }
        for candidate in [
            "/opt/homebrew/bin/openconnect",
            "/usr/local/bin/openconnect",
            "/run/current-system/sw/bin/openconnect",
        ] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "openconnect"
    }

    nonisolated private static func findExecutableInPath(_ name: String) -> String? {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// True if `pid` exists (`kill(pid, 0)` succeeds, or fails with EPERM
    /// because it's root-owned) AND its process name matches
    /// `expectedName` (guards against a reused PID after openconnect
    /// exits — mirrors `psutil.pid_exists` + name-check in `launcher.py`).
    nonisolated static func isProcessAlive(pid: Int32, expectedName: String) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 && errno == ESRCH {
            return false
        }
        return processName(pid: pid)?.lowercased() == expectedName.lowercased()
    }

    nonisolated private static func processName(pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        return (output as NSString).lastPathComponent
    }
}
