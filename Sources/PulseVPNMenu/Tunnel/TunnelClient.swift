import Foundation
import NetworkExtension
import PulseVPNTunnelProtocol
import notify

enum TunnelClientError: Error, CustomStringConvertible {
    case noSession
    case startRefused(Error)
    case didNotStart
    case noReply
    case badReply
    case preferences(Error)

    var description: String {
        switch self {
        case .noSession: return "The VPN configuration has no session to start."
        case .startRefused(let error): return "The system refused to start the tunnel: \(error.localizedDescription)"
        case .didNotStart: return "The system did not start the tunnel."
        case .noReply: return "The network extension did not answer."
        case .badReply: return "The network extension sent a reply this app couldn't read."
        case .preferences(let error):
            return "Could not save the VPN configuration (it has to be allowed when macOS asks): \(error.localizedDescription)"
        }
    }
}

/// The app's side of the Network Extension: keeps one VPN configuration
/// (`NETunnelProviderManager`) per connection profile — those are the entries
/// in System Settings > VPN — starts and stops tunnels through them, and
/// talks to the running packet tunnel provider.
///
/// The provider can't call the app, so status and log lines are collected by
/// polling it with `sendProviderMessage`: once a second while a session is
/// up, faster while one is starting, and at once whenever the provider posts
/// its "status changed" Darwin notification or the system reports a
/// connection status change.
@MainActor
final class TunnelClient {
    static let shared = TunnelClient()

    /// Every change to the session's status other than its counters.
    var onStatus: ((SessionStatus) -> Void)?
    /// Timestamped session log lines, in order, each delivered once.
    var onLogLines: (([String]) -> Void)?
    /// Something the user should read in the app's own log.
    var onDiagnostic: ((String) -> Void)?
    /// The connection was started outside the app (System Settings > VPN)
    /// and so had no login cookie; the app should sign in and connect it,
    /// which hands the cookie to the waiting provider (see `start`).
    var onLoginNeeded: ((UUID) -> Void)?

    private var managers: [UUID: NETunnelProviderManager] = [:]
    private var managersLoaded = false

    /// The session being followed, if any.
    private var active: (profileID: UUID, manager: NETunnelProviderManager)?
    /// Whether the app started `active` itself (as opposed to noticing it).
    private var appInitiated = false
    /// The system has moved `active` out of "disconnected" at least once, so
    /// seeing "disconnected" again means it ended.
    private var activitySeen = false
    private var sawTunnelUp = false
    /// `onLoginNeeded` has been called for `active`.
    private var loginRequested = false
    private var logCursor = 0
    private var latest: SessionStatus?
    private var lastPushed: SessionStatus?
    private var warnedAboutVersion = false

    private var pollLoop: Task<Void, Never>?
    private var pollInFlight: Task<SessionStatus?, Never>?
    /// Serialises everything that reads or writes the saved configurations.
    private var preferencesTail: Task<Void, Never>?

    private var darwinToken: Int32 = 0

    private init() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            nonisolated(unsafe) let connection = note.object as? NEVPNConnection
            MainActor.assumeIsolated {
                if let connection { self?.connectionStatusChanged(connection) }
            }
        }
        notify_register_dispatch(TunnelConstants.statusChangedNotification, &darwinToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollSoon() }
        }
    }

    // MARK: - Saved configurations (System Settings > VPN)

    /// Brings the saved VPN configurations in line with `profiles`: updates
    /// changed ones, removes those whose profile is gone and, if
    /// `createMissing`, adds the rest. The first save makes macOS ask the
    /// user to allow VPN configurations, so creation is left to moments the
    /// user is acting (saving a connection, connecting), not app launch —
    /// unless they have evidently allowed it already (`nil`).
    func sync(profiles: [ConnectionProfile], createMissing: Bool?) async {
        await serialized { [self] in
            do {
                try await loadManagersIfNeeded()
                let wanted = Set(profiles.map(\.id))
                for (id, manager) in managers where !wanted.contains(id) {
                    try? await Self.remove(manager)
                    managers[id] = nil
                }
                let create = createMissing ?? !managers.isEmpty
                for profile in profiles where managers[profile.id] != nil || create {
                    _ = try await ensureManager(for: profile)
                }
            } catch {
                onDiagnostic?("\(TunnelClientError.preferences(error))")
            }
        }
    }

    private func loadManagersIfNeeded() async throws {
        guard !managersLoaded else { return }
        for manager in try await Self.loadAll() {
            if let id = Self.configuration(of: manager)?.profileID, managers[id] == nil {
                managers[id] = manager
            } else {
                // Not one of ours any more (unreadable, or a duplicate).
                try? await Self.remove(manager)
            }
        }
        managersLoaded = true
    }

    /// The saved configuration for `profile`, created or updated as needed
    /// and enabled.
    private func ensureManager(for profile: ConnectionProfile) async throws -> NETunnelProviderManager {
        let manager = managers[profile.id] ?? NETunnelProviderManager()
        let wanted = profile.tunnelConfiguration
        let host = URL(string: profile.vpnURL)?.host ?? profile.vpnURL
        let current = manager.protocolConfiguration as? NETunnelProviderProtocol

        let upToDate = managers[profile.id] != nil
            && Self.configuration(of: manager) == wanted
            && manager.localizedDescription == profile.name
            && current?.serverAddress == host
            && manager.isEnabled
        // Rewriting the configuration of a live tunnel would drop it; it is
        // brought up to date the next time it starts.
        let busy = manager.connection.status != .disconnected && manager.connection.status != .invalid
        if upToDate || (busy && managers[profile.id] != nil) { return manager }

        let proto = current ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = TunnelConstants.extensionBundleIdentifier
        proto.serverAddress = host
        proto.providerConfiguration = wanted.providerConfiguration()
        manager.protocolConfiguration = proto
        manager.localizedDescription = profile.name
        manager.isEnabled = true
        try await Self.save(manager)
        // A freshly saved manager can't start a tunnel until it is reloaded.
        try await Self.load(manager)
        managers[profile.id] = manager
        return manager
    }

    private static func configuration(of manager: NETunnelProviderManager) -> TunnelConfiguration? {
        TunnelConfiguration(
            providerConfiguration: (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration)
    }

    private func serialized(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = preferencesTail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        preferencesTail = task
        await task.value
    }

    // MARK: - Starting and stopping

    /// Starts the tunnel for `profile` with a login cookie and returns once
    /// the system has begun bringing it up. Progress then arrives through
    /// `onStatus`.
    func start(profile: ConnectionProfile, cookie: String) async throws {
        // A start from System Settings is waiting for exactly this cookie:
        // hand it over instead of restarting, so the switch doesn't flicker.
        if let active, active.profileID == profile.id, latest?.awaitingLogin == true,
           let session = active.manager.connection as? NETunnelProviderSession,
           session.status == .connecting {
            appInitiated = true
            deliver(try await send(TunnelRequest(.login, afterLog: logCursor, cookie: cookie), to: session))
            return
        }
        stopFollowing()
        var prepared: Result<NETunnelProviderManager, Error> = .failure(TunnelClientError.noSession)
        await serialized { [self] in
            do {
                try await loadManagersIfNeeded()
                prepared = .success(try await ensureManager(for: profile))
            } catch {
                prepared = .failure(TunnelClientError.preferences(error))
            }
        }
        let manager = try prepared.get()
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw TunnelClientError.noSession
        }

        // Something left over (a stuck attempt, a start from System
        // Settings) has to be gone before a fresh start is accepted.
        if session.status != .disconnected, session.status != .invalid {
            session.stopVPNTunnel()
            _ = await waitUntil(timeout: 10) { session.status == .disconnected || session.status == .invalid }
        }

        follow(profile.id, manager, appInitiated: true)
        do {
            try session.startVPNTunnel(options: [TunnelConstants.cookieOptionKey: cookie as NSString])
        } catch {
            stopFollowing()
            throw TunnelClientError.startRefused(error)
        }
        // Normally seen through the status notification; the direct check
        // covers a notification that is slow to arrive.
        let began = await waitUntil(timeout: 10) {
            self.activitySeen || (session.status != .disconnected && session.status != .invalid)
        }
        activitySeen = activitySeen || began
        guard began else {
            stopFollowing()
            throw TunnelClientError.didNotStart
        }
        startPolling()
    }

    /// The user gave up signing in: stop a tunnel still waiting for the cookie.
    func cancelWaitingForLogin() {
        guard latest?.awaitingLogin == true else { return }
        stop()
    }

    /// Asks the system to stop every tunnel of ours that isn't already down.
    func stop() {
        for manager in managers.values {
            let status = manager.connection.status
            if status != .disconnected, status != .invalid {
                manager.connection.stopVPNTunnel()
            }
        }
    }

    func requestReconnect() async throws {
        guard let session = active?.manager.connection as? NETunnelProviderSession else {
            throw TunnelClientError.noSession
        }
        sawTunnelUp = false
        deliver(try await send(TunnelRequest(.reconnect, afterLog: logCursor), to: session))
    }

    /// The session's status with fresh counters. After a session has ended
    /// this keeps returning its final status until the next `start`.
    func sessionStatus() async throws -> SessionStatus {
        guard active != nil else {
            return latest ?? SessionStatus(state: .none)
        }
        guard let status = await poll() else { throw TunnelClientError.noReply }
        return status
    }

    // MARK: - Sessions the app didn't start in this run

    /// A tunnel that is already up (the app was relaunched while connected).
    func findRunningSession() async -> (profileID: UUID, connectedDate: Date?)? {
        var found: (UUID, Date?)?
        await serialized { [self] in
            try? await loadManagersIfNeeded()
            for (id, manager) in managers {
                let status = manager.connection.status
                if status == .connected || status == .reasserting {
                    found = (id, manager.connection.connectedDate)
                    return
                }
            }
        }
        return found.map { (profileID: $0.0, connectedDate: $0.1) }
    }

    /// Starts following the tunnel `findRunningSession` found.
    func adoptRunningSession(profileID: UUID) {
        guard let manager = managers[profileID] else { return }
        follow(profileID, manager, appInitiated: true)
        activitySeen = true
        startPolling()
    }

    /// Stops following without touching the tunnel.
    func stopFollowing() {
        pollLoop?.cancel()
        pollLoop = nil
        active = nil
    }

    private func follow(_ profileID: UUID, _ manager: NETunnelProviderManager, appInitiated: Bool) {
        pollLoop?.cancel()
        active = (profileID, manager)
        self.appInitiated = appInitiated
        activitySeen = false
        sawTunnelUp = false
        loginRequested = false
        logCursor = 0
        latest = nil
        lastPushed = nil
    }

    private func connectionStatusChanged(_ connection: NEVPNConnection) {
        guard let manager = connection.manager as? NETunnelProviderManager,
              let profileID = Self.configuration(of: manager)?.profileID
        else { return }
        let status = connection.status

        if let active, active.profileID == profileID {
            if status != .disconnected, status != .invalid { activitySeen = true }
            pollSoon()
        } else if active == nil, status == .connecting, let known = managers[profileID] {
            // Switched on in System Settings. It has no login cookie, so the
            // provider is about to say so; follow it to hear that.
            follow(profileID, known, appInitiated: false)
            activitySeen = true
            startPolling()
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollLoop?.cancel()
        pollLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active != nil else { return }
                _ = await self.poll()
                try? await Task.sleep(for: .milliseconds(self.sawTunnelUp ? 1000 : 300))
            }
        }
    }

    private func pollSoon() {
        guard active != nil else { return }
        Task { _ = await poll() }
    }

    /// One exchange with the provider; concurrent callers share it so each
    /// log line is collected once.
    private func poll() async -> SessionStatus? {
        if let pollInFlight { return await pollInFlight.value }
        let task = Task { @MainActor in await self.pollOnce() }
        pollInFlight = task
        let status = await task.value
        pollInFlight = nil
        return status
    }

    private func pollOnce() async -> SessionStatus? {
        guard let (profileID, manager) = active,
              let session = manager.connection as? NETunnelProviderSession
        else { return latest }

        switch session.status {
        case .disconnected, .invalid:
            // Not started yet, or the provider is gone without having told
            // us how it ended.
            guard activitySeen else { return nil }
            let status = await reconstructFinalStatus(session)
            guard active?.profileID == profileID else { return latest }
            finish(with: status)
            return status
        default:
            guard let reply = try? await send(TunnelRequest(.poll, afterLog: logCursor), to: session),
                  active?.profileID == profileID
            else { return nil }
            deliver(reply)
            return reply.status
        }
    }

    private func deliver(_ reply: TunnelReply) {
        guard reply.protocolVersion == TunnelConstants.protocolVersion else {
            if !warnedAboutVersion {
                warnedAboutVersion = true
                onDiagnostic?("The installed network extension speaks protocol \(reply.protocolVersion), but this app needs \(TunnelConstants.protocolVersion). Quit and reopen the app so it can update the extension.")
            }
            stop()
            finish(with: SessionStatus(state: .exited, exitCode: -EPROTONOSUPPORT))
            return
        }
        if !reply.logLines.isEmpty { onLogLines?(reply.logLines) }
        logCursor = reply.lastLogSequence

        if reply.status.snapshot?.linkState == .up, reply.status.snapshot?.espEstablished == true {
            sawTunnelUp = true
        }
        if reply.status.awaitingLogin, !appInitiated, !loginRequested, let profileID = active?.profileID {
            loginRequested = true
            onLoginNeeded?(profileID)
        }
        if reply.status.state == .exited {
            finish(with: reply.status)
        } else {
            push(reply.status)
        }
    }

    /// The session is over: report it and stop following.
    private func finish(with status: SessionStatus) {
        stopFollowing()
        push(status)
    }

    private func push(_ status: SessionStatus) {
        latest = status
        // Counters change every second; they are read, not pushed.
        var comparable = status
        comparable.snapshot?.statsSequence = 0
        comparable.snapshot?.sampledAt = .distantPast
        comparable.snapshot?.txPackets = 0
        comparable.snapshot?.txBytes = 0
        comparable.snapshot?.rxPackets = 0
        comparable.snapshot?.rxBytes = 0
        guard comparable != lastPushed else { return }
        lastPushed = comparable
        onStatus?(status)
    }

    /// What can still be learned once the provider is gone: the error it
    /// (or the system) ended the tunnel with.
    private func reconstructFinalStatus(_ session: NETunnelProviderSession) async -> SessionStatus {
        let error: NSError? = await withCheckedContinuation { continuation in
            session.fetchLastDisconnectError { continuation.resume(returning: $0 as NSError?) }
        }
        var exitCode = -EINTR   // no error: it was asked to stop
        if let error {
            exitCode = error.domain == TunnelConstants.errorDomain ? -Int32(error.code) : -EIO
            if exitCode != TunnelConstants.needsLoginExitCode {
                onDiagnostic?("The tunnel ended: \(error.localizedDescription)")
            }
        }
        return SessionStatus(state: .exited, exitCode: exitCode, startedAt: latest?.startedAt)
    }

    private func send(_ request: TunnelRequest, to session: NETunnelProviderSession) async throws -> TunnelReply {
        guard let data = request.encoded() else { throw TunnelClientError.badReply }
        let reply: Data? = try await withCheckedThrowingContinuation { continuation in
            let once = OneShot(continuation)
            do {
                try session.sendProviderMessage(data) { once.resume(returning: $0) }
            } catch {
                once.resume(throwing: error)
            }
            // A provider that died mid-call never answers.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                once.resume(throwing: TunnelClientError.noReply)
            }
        }
        guard let reply, let decoded = TunnelReply.decode(reply) else { throw TunnelClientError.badReply }
        return decoded
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    // MARK: - NETunnelProviderManager, as async calls

    private static func loadAll() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Unchecked<[NETunnelProviderManager]>, Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: Unchecked(managers ?? []))
                }
            }
        }.value
    }

    private static func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { continuation.resume(with: $0.map(Result.failure) ?? .success(())) }
        }
    }

    private static func load(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { continuation.resume(with: $0.map(Result.failure) ?? .success(())) }
        }
    }

    private static func remove(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.removeFromPreferences { continuation.resume(with: $0.map(Result.failure) ?? .success(())) }
        }
    }
}

/// Carries a non-Sendable value across a continuation that is only ever
/// consumed on the main actor.
private struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Resumes a continuation at most once: a reply and its timeout can race,
/// and resuming a checked continuation twice traps.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) { take()?.resume(returning: value) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
