import AppKit
import Foundation
import Darwin
import PulseVPNHelperProtocol
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
/// to come up, manages routes (`RouteManager`), and relays
/// stop/reconnect/stats requests to the helper.
@MainActor
final class OpenConnectController: ObservableObject {
    @Published private(set) var isBusy = false {
        didSet {
            // A session change that arrived while an action held `isBusy` was
            // only recorded; look at it again now that the action is over.
            if oldValue, !isBusy {
                Task { await self.handleUnexpectedExitIfNeeded() }
            }
        }
    }
    @Published private(set) var connectedProfileID: UUID?

    let stats = StatsHistory()
    let logStore: LogStore
    private let appSettings: AppSettings

    private let routeManager = RouteManager()
    private let authenticator = DSIDAuthenticator()

    private var statsTimerTask: Task<Void, Never>?
    private var runtimeState: RuntimeState?

    /// Set while the helper reports the link as lost and libopenconnect is
    /// retrying on its own, cleared once the link is back up. Only one
    /// "dropped" notification is posted per episode.
    private var inTransientDrop = false

    /// The latest `SessionStatus` the helper has told us about (pushed, or
    /// fetched to resync). Nil until the first one of a new session.
    private var latestStatus: SessionStatus?

    /// Callers parked in `waitForStatus`, resumed when a status satisfies
    /// their predicate or their timeout passes.
    private struct StatusWaiter {
        let predicate: (SessionStatus) -> Bool
        let continuation: CheckedContinuation<SessionStatus?, Never>
    }
    private var waiters: [UUID: StatusWaiter] = [:]

    /// Baselines for noticing change between statuses: the last counter
    /// sample recorded, and the drop count already handled. Both restart at 0
    /// with each new session.
    private var tunnel: (name: String, address: String)?
    private var lastStatsSequence = 0
    private var lastDropCount = 0

    /// Looks up a profile's display name for notifications — set by
    /// `AppState`, which owns the `ConnectionStore` this controller
    /// otherwise has no reference to.
    var profileName: ((UUID) -> String?)?

    static let tunnelTimeout: TimeInterval = 30

    init(logStore: LogStore, appSettings: AppSettings) {
        self.logStore = logStore
        self.appSettings = appSettings
        PrivilegedHelperClient.shared.observe(
            onStatus: { [weak self] status in
                Task { @MainActor in self?.handle(status) }
            },
            onConnectionLost: { [weak self] in
                Task { @MainActor in await self?.resyncWithHelper() }
            }
        )
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
    /// straight to "connected", wait for the traffic counters (refreshed
    /// every second helper-side) to actually advance before setting
    /// `runtimeState`, which is what `isConnected()` reports on. `isBusy` is
    /// held during the check so the UI reads "working…" instead of flashing
    /// "disconnected".
    private func verifyAndReattach(state: RuntimeState) {
        isBusy = true
        logStore.append("Found a recorded VPN session; confirming it's still running…\n")
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }

            do {
                try await PrivilegedHelperClient.shared.verifyProtocolVersion()
            } catch {
                // Leave the recorded state alone: after the helper is updated
                // a later launch can still find the tunnel.
                self.logStore.append("\(error)\n")
                return
            }
            guard let first = try? await PrivilegedHelperClient.shared.sessionStatus() else {
                self.logStore.append("Could not reach the helper; not reattaching.\n")
                return
            }
            guard first.isRunning else {
                self.logStore.append("The recorded VPN session is no longer running.\n")
                RuntimeState.clear()
                return
            }

            let baseline = first.snapshot?.statsSequence ?? 0
            var confirmed: SessionStatus?
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(1100))
                if let status = try? await PrivilegedHelperClient.shared.sessionStatus(),
                   status.isRunning, (status.snapshot?.statsSequence ?? 0) > baseline {
                    confirmed = status
                    break
                }
            }
            guard let status = confirmed else {
                self.logStore.append("Could not confirm the existing VPN session is responding; not reattaching.\n")
                RuntimeState.clear()
                return
            }
            // Drops that happened before we got here aren't news.
            self.lastDropCount = status.snapshot?.dropCount ?? 0
            self.lastStatsSequence = 0
            self.handle(status, recordSample: true)

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

    /// e.g. "utun6, 172.25.228.228", from the interface the helper's session
    /// actually created (refreshed with each snapshot).
    var connectedInterfaceDescription: String? {
        guard isConnected(), let tunnel else { return nil }
        return "\(tunnel.name), \(tunnel.address)"
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

        do {
            try await PrivilegedHelperClient.shared.verifyProtocolVersion()
        } catch {
            logStore.append("\(error)\n")
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
        inTransientDrop = false
        lastStatsSequence = 0
        lastDropCount = 0
        // The previous session's final status would satisfy "has ended".
        latestStatus = nil

        let script = profile.script.flatMap { $0.isEmpty ? nil : $0 } ?? Self.bundledVPNCScriptPath
        try await PrivilegedHelperClient.shared.startSession(
            url: profile.vpnURL,
            cookie: dsidValue,
            vpncScript: script,
            pinnedCertHash: profile.pinnedCertHash,
            verbose: profile.debug,
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

        // Up means the session reached ESP *and* the tunnel has an address;
        // the interface alone isn't enough. Ending first means failure.
        guard let status = await waitForStatus(timeout: Self.tunnelTimeout, until: Self.isTunnelUp) else {
            throw ConnectError.tunnelTimeout
        }
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

        guard let ip = status.snapshot?.address else { throw ConnectError.tunnelTimeout }
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

        _ = await waitForStatus(timeout: 10) { !$0.isRunning }

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
        tunnel = nil
    }

    func reconnect() async throws {
        guard let state = runtimeState else { return }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        inTransientDrop = false
        // The ESP flag in whatever we last heard is about the old link.
        latestStatus = nil
        try await PrivilegedHelperClient.shared.requestReconnect()
        logStore.append("Asked the VPN session to reconnect.\n")

        guard let status = await waitForStatus(timeout: Self.tunnelTimeout, until: Self.isTunnelUp) else {
            logStore.append("Reconnect timed out waiting for the tunnel to come back up.\n")
            return
        }
        guard status.isRunning, let ip = status.snapshot?.address else {
            logStore.append("Reconnect failed: the VPN session ended.\n")
            // The user asked for a reconnect, not a disconnect — losing
            // the tunnel here is just as unrequested as below.
            notifyLost(state: state, reason: "Reconnect failed.")
            await tearDownAfterExit(state: state)
            return
        }

        var updated = state
        updated.vpnGatewayIP = ip
        updated.save()
        runtimeState = updated
        if !updated.noDefaultRoute {
            try await routeManager.setDefaultRoute(gatewayIP: ip)
        }
        logStore.append("Reconnected; VPN interface IP: \(ip)\n")
    }

    // MARK: - Unrequested disconnects

    /// Catches the session ending on its own — session expiry,
    /// `--reconnect-timeout` running out, a helper crash — and does the
    /// cleanup `disconnect()` would have done, plus an optional notification.
    /// Runs off the status the helper pushed (see `handle`), and again when
    /// an action that held `isBusy` finishes. Every user-requested path
    /// (`connect`, `disconnect`, `reconnect`, Quit) runs under `isBusy` and
    /// clears `runtimeState` itself, so it never gets here.
    func handleUnexpectedExitIfNeeded() async {
        guard !isBusy, let state = runtimeState,
              let status = latestStatus, !status.isRunning else { return }
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
        tunnel = nil
    }

    private func notifyLost(state: RuntimeState, reason: String) {
        guard appSettings.notifyOnUnexpectedDisconnect else { return }
        Notifier.shared.post(.lost, title: "VPN disconnected", body: "\(profileLabel(state)): \(reason)")
    }

    // MARK: - Helper status

    /// Takes in a `SessionStatus` — pushed by the helper, or fetched to
    /// resync — and wakes anyone waiting on it. `recordSample` is for the
    /// stats timer's reads: pushed statuses carry the counters as they
    /// happened to be, so only deliberate reads add a graph point.
    func handle(_ status: SessionStatus, recordSample: Bool = false) {
        latestStatus = status
        if let snapshot = status.snapshot {
            apply(snapshot, recordSample: recordSample)
        }
        for (id, waiter) in waiters where waiter.predicate(status) {
            resolveWaiter(id, with: status)
        }
        Task { await handleUnexpectedExitIfNeeded() }
    }

    /// After the XPC connection dropped (the helper may have crashed), pushed
    /// changes may have been missed: ask for the truth once.
    private func resyncWithHelper() async {
        guard let status = try? await PrivilegedHelperClient.shared.sessionStatus() else { return }
        handle(status)
    }

    /// Suspends until a status satisfies `predicate` or `timeout` passes
    /// (nil). Checks what we already know, then asks the helper once in case
    /// the change it's waiting for was pushed before we started waiting.
    private func waitForStatus(
        timeout: TimeInterval,
        until predicate: @escaping (SessionStatus) -> Bool
    ) async -> SessionStatus? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = StatusWaiter(predicate: predicate, continuation: continuation)
            if let latest = latestStatus, predicate(latest) {
                resolveWaiter(id, with: latest)
                return
            }
            Task { [weak self] in
                if let status = try? await PrivilegedHelperClient.shared.sessionStatus() {
                    self?.handle(status)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.resolveWaiter(id, with: nil)
            }
        }
    }

    private func resolveWaiter(_ id: UUID, with status: SessionStatus?) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: status)
    }

    /// "Up" for connect/reconnect: the session ended (nothing more to wait
    /// for), or ESP is established and the tunnel has an address.
    private static func isTunnelUp(_ status: SessionStatus) -> Bool {
        !status.isRunning || (status.snapshot?.espEstablished == true && status.snapshot?.address != nil)
    }

    /// Folds a snapshot into app state: the tunnel identity, drop/restore
    /// transitions (with their notifications), and — when `recordSample` —
    /// a new traffic sample.
    private func apply(_ snapshot: SessionSnapshot, recordSample: Bool) {
        if let name = snapshot.interfaceName, let address = snapshot.address {
            tunnel = (name, address)
        }

        if recordSample, snapshot.statsSequence > 0, snapshot.statsSequence != lastStatsSequence {
            lastStatsSequence = snapshot.statsSequence
            stats.append(snapshot)
        }

        if snapshot.dropCount > lastDropCount {
            lastDropCount = snapshot.dropCount
            transientDropStarted()
        }
        if snapshot.linkState == .up {
            transientDropEnded()
        }
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
            // Poll once immediately rather than waiting out the first
            // interval — the caller just confirmed (or established) the
            // tunnel, so there's no reason to sit without stats for up to
            // a full poll interval before the first sample appears.
            await self.refreshCounters()
            while !Task.isCancelled {
                // Re-read on every iteration (rather than capturing once)
                // so a change made in Settings while connected takes
                // effect on the very next tick.
                let interval = self.appSettings.statsPollInterval
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                guard self.isConnected() else { break }
                await self.refreshCounters()
            }
        }
    }

    /// The helper refreshes the counters every second; this reads them at
    /// the user's chosen interval and adds a graph point.
    private func refreshCounters() async {
        guard let status = try? await PrivilegedHelperClient.shared.sessionStatus() else { return }
        handle(status, recordSample: true)
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
