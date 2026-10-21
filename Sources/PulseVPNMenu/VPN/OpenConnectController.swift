import AppKit
import Foundation
import Darwin
import ServiceManagement

enum ConnectExitOutcome {
    case up
    case rejectedCookie
    /// The server certificate failed validation; the user can pin it.
    case untrustedCert(CertFailure)
    case failed(Int32)
}

struct ConnectAttemptResult {
    let outcome: ConnectExitOutcome
    /// The DSID actually used for this attempt (reused from the profile or
    /// freshly fetched via the browser), so the caller can persist it.
    let dsidUsed: String?
}

enum ConnectError: Error, CustomStringConvertible {
    case tunnelTimeout
    case noCookie

    var description: String {
        switch self {
        case .tunnelTimeout: return "Could not find a valid VPN interface with an IPv4 address."
        case .noCookie: return "Could not obtain a login cookie."
        }
    }
}

/// Mirrors `launcher.py`'s `OpenconnectPulseLauncher`: authenticates (via
/// `DSIDAuthenticator`), starts the VPN session in the privileged helper
/// daemon (`PrivilegedHelperClient`; libopenconnect runs in-process there,
/// as root), waits for the tunnel interface
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

    /// Set when openconnect logs that it lost the link but is retrying on
    /// its own (the process stays alive — see `transientDropMarkers`), and
    /// cleared once ESP is re-established. Only one "dropped" notification
    /// is posted per episode, however many retry lines follow.
    private var inTransientDrop = false

    /// openconnect's own messages for "the link went away, retrying within
    /// `--reconnect-timeout`" (DPD timeouts, the server closing the
    /// session, `ssl_reconnect`'s backoff lines). Matched case-insensitively.
    private static let transientDropMarkers = [
        "detected dead peer",
        "server closed connection",
        "failed to reconnect to host",
        "remaining timeout",
    ]

    /// Looks up a profile's display name for notifications — set by
    /// `AppState`, which owns the `ConnectionStore` this controller
    /// otherwise has no reference to.
    var profileName: ((UUID) -> String?)?

    static let tunnelTimeout: TimeInterval = 30

    init(logStore: LogStore, appSettings: AppSettings) {
        self.logStore = logStore
        self.appSettings = appSettings
        logStore.onLine = { [weak self] line in
            self?.stats.ingest(line)
            if line.contains("ESP session established with server") {
                self?.espEstablished = true
                self?.transientDropEnded()
            } else {
                let lowered = line.lowercased()
                if Self.transientDropMarkers.contains(where: { lowered.contains($0) }) {
                    self?.transientDropStarted()
                }
            }
        }

        // A session lives in the helper and outlives the app: if we recorded
        // one, ask the helper whether it's still up and reattach. (Only when
        // the helper is already approved — launch must not trigger a
        // registration prompt.)
        if let state = RuntimeState.load() {
            if PrivilegedHelperClient.shared.status == .enabled {
                verifyAndReattach(state: state)
            } else {
                RuntimeState.clear()
            }
        }
    }

    /// The helper reporting a running session isn't proof the tunnel is
    /// actually up — it can be wedged or mid-reconnect. Rather than flipping
    /// straight to "connected", request a stats update and wait for a real
    /// sample to come back (`StatsHistory` only grows once a genuine stats
    /// line is parsed from the log) before setting `runtimeState`, which is
    /// what `isConnected()` reports on. `isBusy` is held during the check so
    /// the UI reads "working…" instead of flashing "disconnected".
    private func verifyAndReattach(state: RuntimeState) {
        isBusy = true
        logStore.append("Found a recorded VPN session; confirming it's still running…\n")
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }

            guard let status = try? await PrivilegedHelperClient.shared.sessionStatus() else {
                // Helper unreachable — leave the recorded state alone so a
                // later launch can try again.
                self.logStore.append("Could not reach the helper; not reattaching.\n")
                return
            }
            guard status.isRunning else {
                self.logStore.append("The recorded VPN session is no longer running.\n")
                RuntimeState.clear()
                return
            }

            let sampleCountBefore = self.stats.samples.count
            try? await PrivilegedHelperClient.shared.requestStatsUpdate()

            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if self.stats.samples.count > sampleCountBefore { break }
                try? await Task.sleep(for: .milliseconds(200))
            }

            guard self.stats.samples.count > sampleCountBefore else {
                self.logStore.append("Could not confirm the existing VPN session is responding; not reattaching.\n")
                RuntimeState.clear()
                return
            }

            self.runtimeState = state
            self.connectedProfileID = state.profileID
            self.logStore.append("Confirmed and reattached to the VPN session.\n")
            self.startStatsTimer()
        }
    }

    // MARK: - Status

    /// Cheap and synchronous (read from SwiftUI and the status timer); a
    /// session that died on its own is noticed by
    /// `handleUnexpectedExitIfNeeded`, which clears `runtimeState`.
    func isConnected() -> Bool {
        runtimeState != nil
    }

    /// When the VPN session currently being tracked was started —
    /// read off the persisted `RuntimeState`, so a session's duration
    /// survives an app relaunch that reattaches to a still-running tunnel
    /// instead of restarting from zero.
    ///
    /// Callers read this from inside a SwiftUI view body, so it must stay a
    /// plain property read — anything that re-enters the run loop mid-render
    /// (a subprocess spawn, a synchronous XPC call) crashes SwiftUI's
    /// AttributeGraph ("modifying state during view update").
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
                    logStore.append("The server rejected the DSID cookie; re-authenticating.\n")
                    continue
                case .untrustedCert(let failure):
                    guard let hash = failure.hash,
                          confirmTrust(failure, hash: hash, profile: workingProfile) else {
                        logStore.append("Server certificate not trusted: \(failure.reason)\n")
                        return
                    }
                    workingProfile.pinnedCertHash = hash
                    store.updatePinnedCertHash(profileID: workingProfile.id, hash: hash)
                    logStore.append("Pinned server certificate \(hash).\n")
                    continue
                case .failed(let code):
                    logStore.append("The VPN session ended with code \(code) before the tunnel came up.\n")
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
        let hostname = URL(string: profile.vpnURL)?.host
        let originalGatewayIP = NetworkInterfaces.defaultGatewayIP()

        var dsid = profile.lastDSID
        if dsid == nil || dsid?.isEmpty == true {
            dsid = try await authenticator.fetchDSID(vpnURL: profile.vpnURL)
        }
        guard let dsidValue = dsid, !dsidValue.isEmpty else {
            throw ConnectError.noCookie
        }

        try AppPaths.prepareForNewConnection()
        logStore.resetForNewConnection()
        stats.clear()
        espEstablished = false
        inTransientDrop = false

        let script = profile.script.flatMap { $0.isEmpty ? nil : $0 } ?? Self.bundledVPNCScriptPath
        try await PrivilegedHelperClient.shared.startSession(
            url: profile.vpnURL,
            cookie: dsidValue,
            vpncScript: script,
            pinnedCertHash: profile.pinnedCertHash,
            logFile: AppPaths.currentLogFile
        )

        var state = RuntimeState(
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
            let status = try await PrivilegedHelperClient.shared.sessionStatus()
            if !status.isRunning {
                runtimeState = nil
                RuntimeState.clear()
                if let failure = status.certFailure {
                    return ConnectAttemptResult(outcome: .untrustedCert(failure), dsidUsed: dsidValue)
                }
                if status.exitCode == -EPERM {
                    return ConnectAttemptResult(outcome: .rejectedCookie, dsidUsed: dsidValue)
                }
                return ConnectAttemptResult(outcome: .failed(status.exitCode), dsidUsed: dsidValue)
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
                startStatsTimer()
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
            try await PrivilegedHelperClient.shared.stopSession()
            logStore.append("Asked the VPN session to stop.\n")
        } catch {
            logStore.append("Failed to stop the VPN session: \(error)\n")
        }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !(await sessionIsRunning()) { break }
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
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        espEstablished = false
        inTransientDrop = false
        try await PrivilegedHelperClient.shared.requestReconnect()
        logStore.append("Asked the VPN session to reconnect.\n")

        let deadline = Date().addingTimeInterval(Self.tunnelTimeout)
        while Date() < deadline {
            if !(await sessionIsRunning()) {
                logStore.append("Reconnect failed: the VPN session ended.\n")
                // The user asked for a reconnect, not a disconnect — losing
                // the tunnel here is just as unrequested as below.
                notifyLost(state: state, reason: "Reconnect failed.")
                await tearDownAfterExit(state: state)
                return
            }

            if espEstablished, let (_, ip) = NetworkInterfaces.findVPNInterface() {
                var updated = state
                updated.vpnGatewayIP = ip
                updated.save()
                runtimeState = updated
                if !updated.noDefaultRoute {
                    try await routeManager.setDefaultRoute(gatewayIP: ip)
                }
                logStore.append("Reconnected; VPN interface IP: \(ip)\n")
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        logStore.append("Reconnect timed out waiting for the tunnel to come back up.\n")
    }

    // MARK: - Unrequested disconnects

    /// Called from `AppState`'s periodic refresh. Catches the session ending
    /// on its own — session expiry, `--reconnect-timeout` running out, a
    /// helper crash — and does the cleanup `disconnect()` would have done,
    /// plus an optional notification. Every user-requested path (`connect`,
    /// `disconnect`, `reconnect`, Quit) runs under `isBusy` and clears
    /// `runtimeState` itself, so it never gets here.
    func handleUnexpectedExitIfNeeded() async {
        guard !isBusy, runtimeState != nil else { return }
        // If the helper can't be reached, say nothing: that's not evidence
        // the tunnel is gone.
        guard let status = try? await PrivilegedHelperClient.shared.sessionStatus(),
              !status.isRunning else { return }
        // Re-check after the await: a user action may have started meanwhile.
        guard !isBusy, let state = runtimeState else { return }
        isBusy = true
        defer { isBusy = false }

        let reason: String
        switch (status.state, status.exitCode) {
        case (.exited, -EPERM):
            logStore.append("The VPN session was rejected by the server.\n")
            reason = "The session expired or was rejected by the server."
        case (.exited, -EPIPE):
            logStore.append("The server ended the VPN session.\n")
            reason = "The server ended the session."
        case (.exited, let code):
            logStore.append("The VPN session ended unexpectedly (code \(code)).\n")
            reason = "The VPN session ended (code \(code))."
        case (.none, _), (.running, _):
            // The helper restarted and lost the session.
            logStore.append("The VPN session ended unexpectedly.\n")
            reason = "The VPN session ended unexpectedly."
        }
        notifyLost(state: state, reason: reason)
        await tearDownAfterExit(state: state)
    }

    /// Route/state cleanup after the session has already ended on its own
    /// (nothing left to stop).
    private func tearDownAfterExit(state: RuntimeState) async {
        stopStatsTimer()
        inTransientDrop = false
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

    private func notifyLost(state: RuntimeState, reason: String) {
        guard appSettings.notifyOnUnexpectedDisconnect else { return }
        Notifier.shared.post(.lost, title: "VPN disconnected", body: "\(profileLabel(state)): \(reason)")
    }

    private func transientDropStarted() {
        guard let state = runtimeState, !isBusy, !inTransientDrop else { return }
        inTransientDrop = true
        logStore.append("Connection dropped; reconnecting on its own.\n")
        guard appSettings.notifyOnTransientDrops else { return }
        Notifier.shared.post(.dropped, title: "VPN connection dropped", body: "\(profileLabel(state)): reconnecting…")
    }

    private func transientDropEnded() {
        guard inTransientDrop else { return }
        inTransientDrop = false
        logStore.append("Connection restored.\n")
        guard appSettings.notifyOnTransientDrops, let state = runtimeState else { return }
        Notifier.shared.post(.restored, title: "VPN reconnected", body: "\(profileLabel(state)) is back up.")
    }

    private func profileLabel(_ state: RuntimeState) -> String {
        state.profileID.flatMap { profileName?($0) } ?? "VPN"
    }

    // MARK: - Stats timer

    private func startStatsTimer() {
        stopStatsTimer()
        statsTimerTask = Task { [weak self] in
            guard let self else { return }
            // Request one immediately rather than waiting out the first
            // interval — the caller just confirmed (or established) the
            // tunnel, so there's no reason to sit without stats for up to
            // a full poll interval before the first sample appears.
            try? await PrivilegedHelperClient.shared.requestStatsUpdate()
            while !Task.isCancelled {
                // Re-read on every iteration (rather than capturing once)
                // so a change made in Settings while connected takes
                // effect on the very next tick.
                let interval = self.appSettings.statsPollInterval
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                guard self.isConnected() else { break }
                try? await PrivilegedHelperClient.shared.requestStatsUpdate()
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

    // MARK: - Helpers

    /// Asks the helper; an unreachable helper counts as "not running" for the
    /// callers' wait loops (they have their own deadlines).
    private func sessionIsRunning() async -> Bool {
        (try? await PrivilegedHelperClient.shared.sessionStatus())?.isRunning ?? false
    }

    /// Modal prompt to pin a certificate that failed normal validation. The
    /// fingerprint is the thing to verify out-of-band; "Cancel" is the
    /// default button.
    private func confirmTrust(_ failure: CertFailure, hash: String, profile: ConnectionProfile) -> Bool {
        let changed = profile.pinnedCertHash != nil
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = changed ? "The server certificate has changed" : "Trust this server certificate?"
        alert.informativeText = """
            \(profile.name) presented a certificate that isn't trusted:

            \(failure.reason)

            Fingerprint:
            \(hash)

            \(changed ? "It differs from the certificate you previously trusted. " : "")Only continue if you have verified the fingerprint. Future connections will accept exactly this certificate.
            """
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Trust and Connect")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Bundled by build.sh; nil when running an unbundled debug build, in
    /// which case libopenconnect configures no DNS/routes unless the profile
    /// supplies its own script.
    nonisolated static var bundledVPNCScriptPath: String? {
        Bundle.main.url(forResource: "vpnc-script", withExtension: nil)?.path
    }
}
