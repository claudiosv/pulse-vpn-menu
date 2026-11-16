import AppKit
import Foundation
import Darwin
import OpenConnectTunnelProtocol

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
/// `DSIDAuthenticator`), starts the VPN session in the packet tunnel system
/// extension (`TunnelClient`; libopenconnect runs in-process there), waits
/// for the tunnel to come up, and relays stop/reconnect/stats requests to
/// it. Routes and DNS are the system's business now: the extension hands
/// them to Network Extension, which also removes them when the tunnel ends.
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

    private let authenticator = DSIDAuthenticator()

    private var statsTimerTask: Task<Void, Never>?
    private var runtimeState: RuntimeState?

    /// Set while the extension reports the link as lost and libopenconnect is
    /// retrying on its own, cleared once the link is back up. Only one
    /// "dropped" notification is posted per episode.
    private var inTransientDrop = false

    /// The latest `SessionStatus` the extension has told us about. Nil until
    /// the first one of a new session.
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
    private var tunnel: (name: String?, address: String)?
    /// The DNS servers the tunnel put in place and the domains they answer
    /// for (nil: everything); nil if it set none.
    private var tunnelDNS: (servers: [String], domains: [String]?)?
    private var lastStatsSequence = 0
    private var lastDropCount = 0

    /// Looks up a profile's display name for notifications — set by
    /// `AppState`, which owns the `ConnectionStore` this controller
    /// otherwise has no reference to.
    var profileName: ((UUID) -> String?)?

    /// A connection was switched on in System Settings > VPN. It can't
    /// start there (the login cookie comes from the app's browser flow), so
    /// `AppState` answers by connecting that profile the normal way.
    var externalConnectRequested: ((UUID) -> Void)?

    /// Forgets a profile's cached login cookie. Stopping the tunnel logs the
    /// session off on the server, which kills the cookie, so the next
    /// connect should go straight to the browser login.
    var clearSavedLogin: ((UUID) -> Void)?

    static let tunnelTimeout: TimeInterval = 30
    /// How long connect waits for ESP before settling for the TLS fallback
    /// (UDP 4500 blocked, say). Normally ESP is up within a second or two.
    static let espGrace: TimeInterval = 12

    /// Whether the last snapshot had ESP established; false means traffic
    /// runs over the TLS connection.
    private var tunnelUsesESP = false

    /// When the login expires, and the expiry the warning notification is
    /// scheduled for.
    private var loginExpiry: Date?
    private var warnedExpiry: Date?
    /// How long before the login runs out the warning is posted.
    private static let expiryWarning: TimeInterval = 10 * 60

    /// Demo mode's stand-in for `runtimeState`: when the simulated session
    /// started, plus the counter generator feeding `stats`. Nil whenever
    /// the simulated tunnel is "down" (and always nil outside demo mode).
    private var demoStartedAt: Date?
    private var demoTraffic = DemoTraffic()

    init(logStore: LogStore, appSettings: AppSettings) {
        self.logStore = logStore
        self.appSettings = appSettings
        // Demo mode must not follow the tunnel extension at all: any real
        // session belongs to a real instance of the app.
        if DemoMode.isEnabled {
            logStore.append("Demo mode: simulating a VPN connection; nothing real is touched.\n")
            startDemoSession(profileID: nil, alreadyRunning: true)
            return
        }
        let client = TunnelClient.shared
        client.onStatus = { [weak self] status in self?.handle(status) }
        client.onLogLines = { lines in SessionLogFile.append(lines) }
        client.onDiagnostic = { [weak self] text in self?.logStore.append(text + "\n") }
        client.onLoginNeeded = { [weak self] profileID in
            self?.logStore.append("A connection was switched on in System Settings; signing in…\n")
            self?.externalConnectRequested?(profileID)
        }
        reattachIfRunning()
    }

    /// A tunnel lives in the system extension and outlives the app: if one
    /// is up at launch, follow it again. The system saying "connected" isn't
    /// proof the session is healthy — it can be wedged or mid-reconnect — so
    /// wait for the traffic counters (refreshed every second in the
    /// extension) to actually advance before setting `runtimeState`, which is
    /// what `isConnected()` reports on. `isBusy` is held during the check so
    /// the UI reads "working…" instead of flashing "disconnected".
    private func reattachIfRunning() {
        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }

            guard let found = await TunnelClient.shared.findRunningSession() else { return }
            self.logStore.append("Found a running VPN session; confirming it's responding…\n")
            // The extension hands over every log line it still holds, so
            // start the session log afresh rather than repeat them.
            try? AppPaths.prepareForNewConnection()
            self.logStore.resetForNewConnection()
            TunnelClient.shared.adoptRunningSession(profileID: found.profileID)

            guard let first = try? await TunnelClient.shared.sessionStatus(), first.isRunning else {
                self.logStore.append("The VPN session is not responding; not reattaching.\n")
                TunnelClient.shared.stopFollowing()
                return
            }
            let baseline = first.snapshot?.statsSequence ?? 0
            var confirmed: SessionStatus?
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(1100))
                if let status = try? await TunnelClient.shared.sessionStatus(),
                   status.isRunning, (status.snapshot?.statsSequence ?? 0) > baseline {
                    confirmed = status
                    break
                }
            }
            guard let status = confirmed else {
                self.logStore.append("Could not confirm the existing VPN session is responding; not reattaching.\n")
                TunnelClient.shared.stopFollowing()
                return
            }
            // Drops that happened before we got here aren't news.
            self.lastDropCount = status.snapshot?.dropCount ?? 0
            self.lastStatsSequence = 0
            self.handle(status, recordSample: true)

            self.runtimeState = RuntimeState(
                profileID: found.profileID,
                startedAt: found.connectedDate ?? status.startedAt ?? Date()
            )
            self.connectedProfileID = found.profileID
            self.logStore.append("Confirmed and reattached to the VPN session.\n")
            self.startStatsTimer()
        }
    }

    // MARK: - Status

    /// Cheap and synchronous (read from SwiftUI and the status timer); a
    /// session that died on its own is noticed by
    /// `handleUnexpectedExitIfNeeded`, which clears `runtimeState`.
    func isConnected() -> Bool {
        runtimeState != nil || demoStartedAt != nil
    }

    /// When the VPN session currently being tracked was started. After an
    /// app relaunch that reattaches to a still-running tunnel this is the
    /// system's record of when it connected, so the duration doesn't restart
    /// from zero.
    ///
    /// Callers read this from inside a SwiftUI view body, so it must stay a
    /// plain property read — anything that re-enters the run loop mid-render
    /// (a subprocess spawn, a synchronous XPC call) crashes SwiftUI's
    /// AttributeGraph ("modifying state during view update").
    var connectedSince: Date? {
        demoStartedAt ?? runtimeState?.startedAt
    }

    /// e.g. "utun6, 172.25.228.228", from the interface the system created
    /// for the tunnel (refreshed with each snapshot).
    var connectedInterfaceDescription: String? {
        guard isConnected(), let tunnel else { return nil }
        return tunnel.name.map { "\($0), \(tunnel.address)" } ?? tunnel.address
    }

    /// e.g. "169.237.250.250, 169.237.1.250 · ucdavis.edu": the DNS servers
    /// the tunnel put in place and what they answer for. Nil when not
    /// connected or when the tunnel's DNS isn't in use.
    var connectedDNSDescription: String? {
        guard isConnected(), let tunnelDNS else { return nil }
        let scope = tunnelDNS.domains.map { $0.joined(separator: ", ") } ?? "all domains"
        return "\(tunnelDNS.servers.joined(separator: ", ")) · \(scope)"
    }

    /// "ESP (UDP)" or "TLS (TCP)": what the tunnel's traffic runs over. Nil
    /// when not connected.
    var connectedTransport: String? {
        guard isConnected() else { return nil }
        return tunnelUsesESP ? "ESP (UDP)" : "TLS (TCP)"
    }

    /// When the login expires, while connected and if the server said.
    var connectedExpiry: Date? {
        isConnected() ? loginExpiry : nil
    }

    private func scheduleExpiryWarning() {
        guard let expiry = loginExpiry, expiry != warnedExpiry else { return }
        warnedExpiry = expiry
        guard appSettings.notifyOnUnexpectedDisconnect, expiry > Date() else { return }
        let label = tunnelLabelForExpiry()
        Notifier.shared.schedule(
            .expiring, at: expiry.addingTimeInterval(-Self.expiryWarning),
            title: "VPN login expiring",
            body: "\(label) signs out at \(expiry.formatted(date: .omitted, time: .shortened)). Reconnect before then to stay signed in.")
    }

    private func tunnelLabelForExpiry() -> String {
        runtimeState.map { profileLabel($0) } ?? "The VPN"
    }

    private func clearExpiry() {
        loginExpiry = nil
        warnedExpiry = nil
        Notifier.shared.cancel(.expiring)
    }

    /// Just the tunnel's address, e.g. "172.25.228.228", for the menu
    /// header, which has no room for the interface name. A plain property
    /// read, so (like `connectedSince`) it's safe from a view body.
    var connectedAddress: String? {
        guard isConnected() else { return nil }
        return tunnel?.address
    }

    // MARK: - Connect

    /// Authenticate-then-launch-then-retry loop, mirroring `connect()` in
    /// `launcher.py`: on a rejected DSID cookie (exit code 2), clear it and
    /// re-authenticate.
    func connect(profile: ConnectionProfile, store: ConnectionStore) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        if DemoMode.isEnabled {
            logStore.append("Demo mode: pretending to connect to \(profile.name)…\n")
            try? await Task.sleep(for: .milliseconds(1200))
            startDemoSession(profileID: profile.id, alreadyRunning: false)
            return
        }

        // Deliberately re-checked on every connect attempt rather than gated
        // behind a one-shot flag: it is cheap once the extension is active,
        // and it is what installs an updated extension after an app update.
        // Done before the browser login — without the extension the tunnel
        // can never start, so there's no point making the user authenticate
        // first only to fail at the very last step.
        do {
            switch try await SystemExtensionActivator.shared.activate() {
            case .ready:
                logStore.append("Network extension ready.\n")
            case .needsApproval:
                logStore.append("The VPN network extension needs to be allowed in System Settings > General > Login Items & Extensions > Network Extensions. Allow it, then connect again.\n")
                return
            }
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
                TunnelClient.shared.cancelWaitingForLogin()
                return
            }
        }
    }

    /// Single connect attempt: authenticate if needed, start the tunnel,
    /// wait for it to come up. Mirrors `connect_once()` in `launcher.py`.
    func connectOnce(profile: ConnectionProfile) async throws -> ConnectAttemptResult {
        var dsid = profile.lastDSID
        if dsid == nil || dsid?.isEmpty == true {
            dsid = try await authenticator.fetchDSID(
                vpnURL: profile.vpnURL, keepBrowserSession: appSettings.keepBrowserSession)
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

        // Saves the profile's VPN configuration if it changed (the first
        // time, macOS asks the user to allow it) and starts it.
        try await TunnelClient.shared.start(profile: profile, cookie: dsidValue)

        runtimeState = RuntimeState(profileID: profile.id, startedAt: Date())

        // Up means the session reached ESP *and* the tunnel has an address;
        // the interface alone isn't enough. Ending first means failure.
        guard let status = await waitForTunnelUp() else {
            throw ConnectError.tunnelTimeout
        }
        if !status.isRunning {
            runtimeState = nil
            if let failure = status.certFailure {
                return ConnectAttemptResult(outcome: .untrustedCert(failure), dsidUsed: dsidValue)
            }
            if status.exitCode == -EPERM {
                return ConnectAttemptResult(outcome: .rejectedCookie, dsidUsed: dsidValue)
            }
            return ConnectAttemptResult(outcome: .failed(status.exitCode), dsidUsed: dsidValue)
        }

        guard status.snapshot?.address != nil else { throw ConnectError.tunnelTimeout }

        if let post = profile.post, !post.isEmpty {
            runPostCommand(post)
        }
        startStatsTimer()
        return ConnectAttemptResult(outcome: .up, dsidUsed: dsidValue)
    }

    // MARK: - Disconnect / reconnect

    func disconnect() async {
        if DemoMode.isEnabled {
            guard demoStartedAt != nil, !isBusy else { return }
            isBusy = true
            defer { isBusy = false }
            try? await Task.sleep(for: .milliseconds(600))
            stopDemoSession()
            logStore.append("Demo mode: simulated session stopped.\n")
            return
        }
        guard runtimeState != nil else { return }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        stopStatsTimer()
        let profileID = runtimeState?.profileID
        if let profileID { await TunnelClient.shared.suspendOnDemand(for: profileID) }

        TunnelClient.shared.stop()
        logStore.append("Asked the VPN session to stop.\n")

        // The system removes the tunnel's routes and DNS itself.
        _ = await waitForStatus(timeout: 10) { !$0.isRunning }

        runtimeState = nil
        connectedProfileID = nil
        tunnel = nil
        tunnelDNS = nil
        clearExpiry()
        if let profileID { clearSavedLogin?(profileID) }
    }

    func reconnect() async throws {
        if DemoMode.isEnabled {
            guard demoStartedAt != nil, !isBusy else { return }
            isBusy = true
            defer { isBusy = false }
            // Like a real reconnect: same session, counters keep running.
            try? await Task.sleep(for: .milliseconds(1500))
            logStore.append("Demo mode: simulated reconnect.\n")
            return
        }
        guard let state = runtimeState else { return }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        inTransientDrop = false
        // The ESP flag in whatever we last heard is about the old link.
        latestStatus = nil
        try await TunnelClient.shared.requestReconnect()
        logStore.append("Asked the VPN session to reconnect.\n")

        guard let status = await waitForTunnelUp() else {
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

        logStore.append("Reconnected; VPN interface IP: \(ip)\n")
    }

    // MARK: - Unrequested disconnects

    /// Catches the session ending on its own — session expiry,
    /// `--reconnect-timeout` running out, an extension crash, the switch in
    /// System Settings > VPN — and does the cleanup `disconnect()` would have
    /// done, plus an optional notification.
    /// Runs off the status the extension reported (see `handle`), and again when
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
        case (.exited, -EINTR):
            // Stopped on request, just not ours: System Settings > VPN.
            logStore.append("The VPN was disconnected outside the app.\n")
            if let profileID = state.profileID { clearSavedLogin?(profileID) }
            await tearDownAfterExit(state: state)
            return
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
            // The extension restarted and lost the session.
            logStore.append("The VPN session ended unexpectedly.\n")
            reason = "The VPN session ended unexpectedly."
        }
        notifyLost(state: state, reason: reason)
        await tearDownAfterExit(state: state)
    }

    /// State cleanup after the session has already ended on its own (nothing
    /// left to stop; the system has removed its routes and DNS).
    private func tearDownAfterExit(state: RuntimeState) async {
        stopStatsTimer()
        inTransientDrop = false
        runtimeState = nil
        connectedProfileID = nil
        tunnel = nil
        tunnelDNS = nil
        clearExpiry()
    }

    private func notifyLost(state: RuntimeState, reason: String) {
        guard appSettings.notifyOnUnexpectedDisconnect else { return }
        Notifier.shared.post(.lost, title: "VPN disconnected", body: "\(profileLabel(state)): \(reason)")
    }

    // MARK: - Session status

    /// Takes in a `SessionStatus` — reported by `TunnelClient` when it
    /// changes, or fetched — and wakes anyone waiting on it. `recordSample`
    /// is for the stats timer's reads: reported statuses carry the counters
    /// as they happened to be, so only deliberate reads add a graph point.
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

    /// Suspends until a status satisfies `predicate` or `timeout` passes
    /// (nil). Checks what we already know, then asks the extension once in
    /// case the change it's waiting for happened before we started waiting.
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
                if let status = try? await TunnelClient.shared.sessionStatus() {
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

    /// Waits for the tunnel to be usable: ESP established, or after
    /// `espGrace` the link up over TLS alone. Nil on timeout.
    private func waitForTunnelUp() async -> SessionStatus? {
        if let status = await waitForStatus(timeout: Self.espGrace, until: Self.isTunnelUp) {
            return status
        }
        if let status = latestStatus, status.isRunning,
           status.snapshot?.address != nil, status.snapshot?.linkState == .up {
            logStore.append("ESP did not come up; using the TLS connection instead.\n")
            return status
        }
        return await waitForStatus(timeout: Self.tunnelTimeout - Self.espGrace, until: Self.isTunnelUp)
    }

    /// "Up" for connect/reconnect: the session ended (nothing more to wait
    /// for), or ESP is established and the tunnel has an address. A provider
    /// that hasn't started its session yet (`.none`) is neither: it is
    /// still starting, and reading that as "ended" reported a failure for a
    /// tunnel that came up a moment later.
    private static func isTunnelUp(_ status: SessionStatus) -> Bool {
        status.state == .exited || (status.snapshot?.espEstablished == true && status.snapshot?.address != nil)
    }

    /// Folds a snapshot into app state: the tunnel identity, drop/restore
    /// transitions (with their notifications), and — when `recordSample` —
    /// a new traffic sample.
    private func apply(_ snapshot: SessionSnapshot, recordSample: Bool) {
        if let address = snapshot.address {
            tunnel = (snapshot.interfaceName, address)
        }
        tunnelUsesESP = snapshot.espEstablished
        loginExpiry = snapshot.expiresAt
        scheduleExpiryWarning()
        if let servers = snapshot.dnsServers, !servers.isEmpty {
            tunnelDNS = (servers, snapshot.dnsDomains)
        } else {
            tunnelDNS = nil
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

    /// The extension refreshes the counters every second; this reads them at
    /// the user's chosen interval and adds a graph point.
    private func refreshCounters() async {
        guard let status = try? await TunnelClient.shared.sessionStatus() else { return }
        handle(status, recordSample: true)
    }

    private func stopStatsTimer() {
        statsTimerTask?.cancel()
        statsTimerTask = nil
    }

    // MARK: - Demo mode

    /// Brings the simulated tunnel "up" (see `DemoMode`). `alreadyRunning`
    /// is the launch case: the session claims to be hours old and the graph
    /// history is prefilled, as if the app had reattached to a tunnel that
    /// was up all along. A Connect click instead starts from zero, so the
    /// graph filling in from empty can be watched too.
    private func startDemoSession(profileID: UUID?, alreadyRunning: Bool) {
        stopStatsTimer()
        stats.clear()

        let now = Date()
        let interval = appSettings.statsPollInterval
        if alreadyRunning {
            demoTraffic = DemoTraffic(rxBytes: DemoMode.launchRxBytes, txBytes: DemoMode.launchTxBytes)
            for step in (0..<DemoMode.launchSampleCount).reversed() {
                demoTraffic.advance(by: interval)
                stats.append(demoTraffic.sample(at: now.addingTimeInterval(-Double(step) * interval)))
            }
            demoStartedAt = now.addingTimeInterval(-DemoMode.launchSessionAge)
        } else {
            demoTraffic = DemoTraffic()
            stats.append(demoTraffic.sample(at: now))
            demoStartedAt = now
        }
        tunnel = (DemoMode.tunnel.name, DemoMode.tunnel.address)
        connectedProfileID = profileID

        statsTimerTask = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.appSettings.statsPollInterval))
                if Task.isCancelled { break }
                let tick = Date()
                self.demoTraffic.advance(by: tick.timeIntervalSince(last))
                self.stats.append(self.demoTraffic.sample(at: tick))
                last = tick
            }
        }
    }

    private func stopDemoSession() {
        stopStatsTimer()
        demoStartedAt = nil
        connectedProfileID = nil
        tunnel = nil
        tunnelDNS = nil
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
}
