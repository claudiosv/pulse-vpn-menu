import Foundation
import Darwin
import ServiceManagement

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
/// `DSIDAuthenticator`), launches openconnect as root (via the privileged
/// helper daemon, `PrivilegedHelperClient`), waits for the tunnel interface
/// to come up, manages routes (`RouteManager`), and delivers signals for
/// stop/reconnect/stats.
@MainActor
final class OpenConnectController: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var connectedProfileID: UUID?

    let stats = StatsHistory()
    let logStore: LogStore
    private let appSettings: AppSettings

    private let routeManager = RouteManager()
    private let authenticator = DSIDAuthenticator()

    private var statsTimerTask: Task<Void, Never>?
    private var runtimeState: RuntimeState?

    /// Set once openconnect's own "ESP session established with server" line
    /// appears in the log for the current connection attempt. The interface
    /// coming up (`Configured as <ip>, with SSL connected and ESP in
    /// progress`) happens first and is not sufficient on its own — the ESP
    /// negotiation can still fail or hang after that point — so
    /// `connectOnce` gates declaring `.up` on this flag as well, not just on
    /// the interface existing.
    private var espEstablished = false

    static let tunnelTimeout: TimeInterval = 30

    init(logStore: LogStore, appSettings: AppSettings) {
        self.logStore = logStore
        self.appSettings = appSettings
        logStore.onLine = { [weak self] line in
            self?.stats.ingest(line)
            if line.contains("ESP session established with server") {
                self?.espEstablished = true
            }
        }

        if let state = RuntimeState.load(), Self.isProcessAlive(pid: state.pid, expectedName: "openconnect") {
            // Every relaunch while already connected — not just the
            // crash/pid-file-recovery case below — needs to reattach, or
            // the stats timer (and thus the periodic stats-request) never
            // resumes and no more RX/TX stats ever show up in the log.
            verifyAndReattach(state: state)
        } else if let recovered = Self.recoverStateFromPidFile() {
            // The app was killed/crashed/relaunched without a clean
            // disconnect, but openconnect itself is still running (it's a
            // detached, privileged process independent of our own
            // lifetime) — reattach instead of showing "disconnected" while
            // a real tunnel is up underneath us. This reattachment is
            // entirely unprivileged (kill(pid,0) + ps name check) and
            // doesn't depend on the helper at all.
            recovered.save()
            verifyAndReattach(state: recovered)
        } else {
            RuntimeState.clear()
        }
    }

    /// A pid existing and matching the expected process name isn't proof
    /// the tunnel is actually up — openconnect can be hung, mid-reconnect,
    /// or wedged. Rather than flipping straight to "connected" on process
    /// presence alone, request a stats update and wait for a real sample to
    /// come back (`StatsHistory` only grows once a genuine SIGUSR1 dump is
    /// parsed from the log) before setting `runtimeState`, which is what
    /// `isConnected()` reports on. `isBusy` is held during the check so the
    /// UI reads "working…" instead of flashing "disconnected".
    private func verifyAndReattach(state: RuntimeState) {
        isBusy = true
        logStore.append("Found an existing openconnect process (pid \(state.pid)); confirming it's responding…\n")
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }

            _ = try? await PrivilegedHelperClient.shared.ensureRegistered()

            let sampleCountBefore = self.stats.samples.count
            try? await PrivilegedHelperClient.shared.requestStatsUpdate(pid: state.pid)

            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if self.stats.samples.count > sampleCountBefore { break }
                guard Self.isProcessAlive(pid: state.pid, expectedName: "openconnect") else {
                    self.logStore.append("Process disappeared while confirming; not reattaching.\n")
                    RuntimeState.clear()
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }

            guard self.stats.samples.count > sampleCountBefore else {
                self.logStore.append("Could not confirm the existing openconnect process is responding; not reattaching.\n")
                RuntimeState.clear()
                return
            }

            self.runtimeState = state
            self.connectedProfileID = state.profileID
            self.logStore.append("Confirmed and reattached to openconnect (pid \(state.pid)).\n")
            self.startStatsTimer(pid: state.pid)
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

    /// When the openconnect process currently being tracked was started —
    /// read off the persisted `RuntimeState`, so a session's duration
    /// survives an app relaunch that reattaches to a still-running tunnel
    /// instead of restarting from zero.
    ///
    /// Deliberately does *not* re-verify liveness via `isConnected()`
    /// (which shells out to `/bin/ps`): callers read this from inside a
    /// SwiftUI view body, already gated on the cheap `AppState.isConnected`
    /// published flag, and re-running a synchronous subprocess spawn on
    /// every view-graph update (e.g. once a second from `TimelineView`)
    /// crashes SwiftUI's AttributeGraph ("modifying state during view
    /// update") — the process spawn re-enters the run loop mid-render.
    var connectedSince: Date? {
        runtimeState?.startedAt
    }

    var connectedInterfaceDescription: String? {
        guard isConnected(), let (name, ip) = NetworkInterfaces.findVPNInterface() else { return nil }
        return "\(name), \(ip)"
    }

    var helperStatus: SMAppService.Status { PrivilegedHelperClient.shared.status }

    // MARK: - Connect

    /// Authenticate-then-launch-then-retry loop, mirroring `connect()` in
    /// `launcher.py`: on a rejected DSID cookie (exit code 2), clear it and
    /// re-authenticate.
    func connect(profile: ConnectionProfile, store: ConnectionStore) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        // Deliberately re-checked on every connect attempt rather than
        // gated behind a one-shot flag: `ensureRegistered()` is cheap when
        // the helper is already `.enabled` (just a hash compare), and this
        // makes registration self-healing if a previous attempt failed
        // (e.g. the register()-right-after-unregister() race) instead of
        // silently never retrying for the rest of the app's lifetime.
        do {
            let status = try await PrivilegedHelperClient.shared.ensureRegistered()
            switch status {
            case .enabled:
                logStore.append("Privileged helper ready.\n")
            case .requiresApproval:
                logStore.append("The VPN helper needs approval in System Settings > General > Login Items & Extensions before connecting will work. Opening System Settings…\n")
                SMAppService.openSystemSettingsLoginItems()
                return
            case .notFound, .notRegistered:
                logStore.append("Could not register the privileged helper.\n")
                return
            @unknown default:
                break
            }
        } catch {
            // Bail out here rather than falling through to the
            // browser-login flow below — without a working helper,
            // openconnect can never actually be launched, so there's no
            // point making the user authenticate first only to fail at the
            // very last step.
            logStore.append("Failed to register privileged helper: \(error)\n")
            return
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
        espEstablished = false

        var argv = [openconnectPath]
        if let script = profile.script, !script.isEmpty {
            argv.append(contentsOf: ["-s", script])
        }
        argv.append(contentsOf: [
            "--reconnect-timeout", "30",
            "--force-dpd", "5",
            "-C", dsidValue,
            "--protocol=pulse",
            profile.vpnURL,
        ])

        // The helper spawns openconnect itself and hands back its real PID
        // synchronously — no more sudo-forking workaround, no pidfile
        // polling.
        let pid = try await PrivilegedHelperClient.shared.launchOpenConnect(
            argv: argv,
            logFile: AppPaths.currentLogFile
        )

        // Keep the PID file current so crash-recovery
        // (`recoverStateFromPidFile`) keeps working exactly as before.
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
            let (known, running, exitCode) = try await PrivilegedHelperClient.shared.processStatus(pid: pid)
            if known, !running {
                runtimeState = nil
                RuntimeState.clear()
                if exitCode == 2 {
                    return ConnectAttemptResult(outcome: .rejectedCookie, dsidUsed: dsidValue)
                }
                return ConnectAttemptResult(outcome: .failed(exitCode), dsidUsed: dsidValue)
            } else if !known, !Self.isProcessAlive(pid: pid, expectedName: "openconnect") {
                // The helper lost track of this pid (e.g. it was restarted
                // mid-connection) AND the unprivileged liveness check also
                // says it's gone — treat as failed rather than guessing at
                // an exit code we don't have.
                runtimeState = nil
                RuntimeState.clear()
                return ConnectAttemptResult(outcome: .failed(-1), dsidUsed: dsidValue)
            }

            if espEstablished, let (_, ip) = NetworkInterfaces.findVPNInterface() {
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
            try await Task.sleep(for: .milliseconds(500))
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
            try await PrivilegedHelperClient.shared.terminateOpenConnect(pid: state.pid)
            logStore.append("Sent SIGTERM to openconnect pid: \(state.pid)\n")
        } catch {
            logStore.append("Failed to send SIGTERM: \(error)\n")
        }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !Self.isProcessAlive(pid: state.pid, expectedName: "openconnect") { break }
            try? await Task.sleep(for: .milliseconds(500))
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
    }

    func reconnect() async throws {
        guard let state = runtimeState else { return }
        try await PrivilegedHelperClient.shared.requestReconnect(pid: state.pid)
        logStore.append("Sent SIGUSR2 to openconnect; reconnecting.\n")
    }

    // MARK: - Stats timer

    private func startStatsTimer(pid: Int32) {
        stopStatsTimer()
        statsTimerTask = Task { [weak self] in
            guard let self else { return }
            // Request one immediately rather than waiting out the first
            // interval — the caller just confirmed (or established) the
            // tunnel, so there's no reason to sit without stats for up to
            // a full poll interval before the first sample appears.
            try? await PrivilegedHelperClient.shared.requestStatsUpdate(pid: pid)
            while !Task.isCancelled {
                // Re-read on every iteration (rather than capturing once)
                // so a change made in Settings while connected takes
                // effect on the very next tick.
                let interval = self.appSettings.statsPollInterval
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                guard self.isConnected() else { break }
                try? await PrivilegedHelperClient.shared.requestStatsUpdate(pid: pid)
            }
        }
    }

    private func stopStatsTimer() {
        statsTimerTask?.cancel()
        statsTimerTask = nil
    }

    private func runPostCommand(_ post: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: post)
        try? process.run()
    }

    // MARK: - Static helpers

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
    /// Entirely unprivileged — doesn't depend on the helper at all.
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
