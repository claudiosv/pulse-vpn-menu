import CryptoKit
import Foundation
import PulseVPNHelperProtocol
import ServiceManagement

enum PrivilegedHelperError: Error, CustomStringConvertible {
    case notEnabled(SMAppService.Status)
    case connectionUnavailable
    /// The XPC connection failed or was interrupted while a call was in flight.
    case connectionFailed(Error)
    case helperError(NSError)
    /// The running helper speaks a different protocol (or none we can read).
    case versionMismatch(helper: Int?, app: Int)
    case badReply

    var description: String {
        switch self {
        case .notEnabled(let status): return "Privileged helper is not enabled (status: \(status))."
        case .connectionUnavailable: return "Could not reach the privileged helper."
        case .connectionFailed(let error): return "Lost contact with the privileged helper: \(error.localizedDescription)"
        case .helperError(let error): return error.localizedDescription
        case .versionMismatch(let helper, let app):
            let found = helper.map { "version \($0)" } ?? "an older version"
            return "The installed privileged helper is \(found), but this app needs version \(app). Quit and reopen the app to update it; if that doesn't help, remove the helper in System Settings > General > Login Items & Extensions and try again."
        case .badReply: return "The privileged helper sent a reply this app couldn't read."
        }
    }
}

/// Talks to the privileged helper daemon over XPC. Replaces
/// `PrivilegedRunner`/`SudoersInstaller`/`ShellQuoting` entirely: no more
/// `sudo`/`osascript`, no shell strings to quote, no `waitForChildPid`
/// process-tree walking (the VPN session runs inside the helper itself,
/// via libopenconnect, so there's no child process to track).
final class PrivilegedHelperClient: @unchecked Sendable {
    static let shared = PrivilegedHelperClient()

    private let daemon = SMAppService.daemon(
        plistName: "\(PrivilegedHelperConstants.machServiceName).plist"
    )
    private var connection: NSXPCConnection?
    private let lock = NSLock()

    var status: SMAppService.Status { daemon.status }

    /// Idempotent — safe to call before every connect attempt. Registers
    /// the daemon if needed (a LaunchDaemon registration requires one-time
    /// admin approval — via a native dialog and/or a trip to System
    /// Settings > General > Login Items & Extensions; which of those
    /// `register()` itself triggers isn't something that can be verified
    /// without actually clicking through it, so callers should re-check
    /// `status` afterward rather than assume `.enabled`).
    ///
    /// Attempts `register()` whenever status isn't already `.enabled` or
    /// `.requiresApproval` — NOT just when it's `.notRegistered`. A daemon
    /// that has never been registered before reports `.notFound` (confirmed
    /// directly via Console: `SMAppService:all Service status: 3` fired on
    /// the very first registration attempt on this machine), not
    /// `.notRegistered` as the header's prose might suggest; checking only
    /// for `.notRegistered` silently skipped `register()` entirely and this
    /// method did nothing on the very first Connect click.
    @discardableResult
    func ensureRegistered() async throws -> SMAppService.Status {
        // SMAppService.h: "If an app updates either the plist or the
        // executable for a LaunchAgent or LaunchDaemon, the SMAppService
        // must be re-registered or it may not launch. It is recommended to
        // also call unregister before re-registering if the executable has
        // been changed." Confirmed empirically this session: replacing the
        // helper binary on disk (via `build.sh --install`) while an OLDER
        // instance of the daemon was still running left it serving from
        // its stale in-memory code indefinitely — simply overwriting the
        // file does nothing on its own. Track a hash of the bundled helper
        // binary so an actual change forces unregister-then-register.
        let currentHash = Self.currentHelperHash()
        let storedHash = try? String(contentsOf: Self.helperHashFile, encoding: .utf8)
        let executableChanged = currentHash != nil && currentHash != storedHash

        if executableChanged {
            // Best-effort: "not currently registered" is expected (and
            // harmless) on the very first run, so any error here is ignored.
            try? await daemon.unregister()
        }

        if executableChanged || (daemon.status != .enabled && daemon.status != .requiresApproval) {
            // Confirmed empirically (Console: "Unregister ... error: 0" then
            // "Register ... error: 1" ~17ms later): calling register()
            // immediately after unregister() can transiently fail because
            // the previous registration's teardown hasn't fully completed
            // yet. Retry with backoff instead of giving up on the first
            // attempt — this is exactly the sequence that left the daemon
            // stuck at .notRegistered after a routine rebuild.
            var lastError: Error?
            for attempt in 0..<5 {
                do {
                    try daemon.register()
                    lastError = nil
                    break
                } catch {
                    let status = daemon.status
                    if status == .enabled || status == .requiresApproval {
                        lastError = nil
                        break
                    }
                    lastError = error
                    if attempt < 4 {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
            }
            if let lastError {
                throw lastError
            }
        }

        if let currentHash, daemon.status == .enabled || daemon.status == .requiresApproval {
            try? currentHash.write(to: Self.helperHashFile, atomically: true, encoding: .utf8)
        }

        return daemon.status
    }

    private static let helperHashFile = AppPaths.appSupportDir.appendingPathComponent("helper-hash.txt")

    /// SHA256 of the currently-bundled helper binary (the one sitting next
    /// to this running app, not necessarily the one the daemon is actually
    /// running right now) — used purely to detect "the app was upgraded
    /// since the daemon was last (re-)registered".
    private static func currentHelperHash() -> String? {
        guard let appExecutable = Bundle.main.executableURL else { return nil }
        let helperURL = appExecutable
            .deletingLastPathComponent()
            .appendingPathComponent("PulseVPNMenuHelper")
        guard let data = try? Data(contentsOf: helperURL) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Pushed session changes

    private let observer = SessionObserverEndpoint()
    private var protocolVerified = false

    /// Registers the app's observer. `onStatus` receives every session change
    /// the helper pushes (it does not carry counters — read those with
    /// `sessionStatus()`); `onConnectionLost` fires when the XPC connection
    /// is interrupted or invalidated (e.g. the helper crashed), after which
    /// pushed state may have been missed and the caller should resync with
    /// `sessionStatus()`. Both are called on arbitrary threads.
    func observe(
        onStatus: @escaping @Sendable (SessionStatus) -> Void,
        onConnectionLost: @escaping @Sendable () -> Void
    ) {
        observer.set(onStatus: onStatus, onConnectionLost: onConnectionLost)
    }

    // MARK: - Connection

    private func connectionOrMake() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }

        let newConnection = NSXPCConnection(
            machServiceName: PrivilegedHelperConstants.machServiceName,
            options: .privileged
        )
        newConnection.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        // The helper pushes session changes back through this.
        newConnection.exportedInterface = NSXPCInterface(with: SessionObserverProtocol.self)
        newConnection.exportedObject = observer
        newConnection.setCodeSigningRequirement(PrivilegedHelperConstants.helperRequirement)
        newConnection.invalidationHandler = { [weak self] in self?.connectionEnded() }
        newConnection.interruptionHandler = { [weak self] in self?.connectionEnded() }
        newConnection.activate()
        connection = newConnection
        return newConnection
    }

    private func connectionEnded() {
        lock.lock()
        connection = nil
        protocolVerified = false
        lock.unlock()
        observer.connectionLost()
    }

    /// The remote proxy, with `onError` called if the connection fails before
    /// a reply arrives — the only signal XPC gives for a call that will never
    /// be answered.
    private func proxy(onError: @escaping @Sendable (Error) -> Void) throws -> PrivilegedHelperProtocol {
        guard status == .enabled else {
            throw PrivilegedHelperError.notEnabled(status)
        }
        let c = connectionOrMake()
        let handler: @Sendable (Error) -> Void = { onError(PrivilegedHelperError.connectionFailed($0)) }
        guard let proxy = c.remoteObjectProxyWithErrorHandler(handler) as? PrivilegedHelperProtocol else {
            throw PrivilegedHelperError.connectionUnavailable
        }
        return proxy
    }

    /// One XPC call as an `async` function. Resumes exactly once: with the
    /// reply, or with the error if the connection fails first.
    private func request<T: Sendable>(
        _ send: @escaping (PrivilegedHelperProtocol, @escaping @Sendable (T) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = OneShot(continuation)
            do {
                let helper = try proxy { once.resume(throwing: $0) }
                send(helper) { once.resume(returning: $0) }
            } catch {
                once.resume(throwing: error)
            }
        }
    }

    /// A call whose reply is just `NSError?`.
    private func requestVoid(
        _ send: @escaping (PrivilegedHelperProtocol, @escaping @Sendable (NSError?) -> Void) -> Void
    ) async throws {
        let error: NSError? = try await request(send)
        if let error { throw PrivilegedHelperError.helperError(error) }
    }

    // MARK: - Typed operations (one async wrapper per protocol method)

    /// Throws `versionMismatch` unless the running helper speaks this app's
    /// protocol. Checked once per XPC connection; call before the first real
    /// request after registering or reconnecting.
    func verifyProtocolVersion() async throws {
        if lock.withLock({ protocolVerified }) { return }
        let found: Int
        do {
            found = try await request { helper, reply in helper.protocolVersion(reply: reply) }
        } catch {
            // A helper that predates the call can't answer it.
            throw PrivilegedHelperError.versionMismatch(helper: nil, app: PrivilegedHelperConstants.protocolVersion)
        }
        guard found == PrivilegedHelperConstants.protocolVersion else {
            throw PrivilegedHelperError.versionMismatch(helper: found, app: PrivilegedHelperConstants.protocolVersion)
        }
        lock.withLock { protocolVerified = true }
    }

    func startSession(
        url: String,
        cookie: String,
        vpncScript: String?,
        pinnedCertHash: String?,
        verbose: Bool,
        logFile: URL
    ) async throws {
        try await requestVoid { helper, reply in
            helper.startSession(
                url: url,
                cookie: cookie,
                vpncScript: vpncScript,
                pinnedCertHash: pinnedCertHash,
                verbose: verbose,
                logPath: logFile.path,
                reply: reply
            )
        }
    }

    func sessionStatus() async throws -> SessionStatus {
        let data: Data = try await request { helper, reply in helper.sessionStatus(reply: reply) }
        guard let status = SessionStatus.decode(data) else { throw PrivilegedHelperError.badReply }
        return status
    }

    func stopSession() async throws {
        try await requestVoid { helper, reply in helper.stopSession(reply: reply) }
    }

    func requestReconnect() async throws {
        try await requestVoid { helper, reply in helper.requestReconnect(reply: reply) }
    }

    func setDefaultRoute(gatewayIP: String) async throws {
        try await requestVoid { helper, reply in helper.setDefaultRoute(gatewayIP: gatewayIP, reply: reply) }
    }

    func addDefaultRoute(gatewayIP: String) async throws {
        try await requestVoid { helper, reply in helper.addDefaultRoute(gatewayIP: gatewayIP, reply: reply) }
    }

    func deleteDefaultRoute(gatewayIP: String) async throws {
        try await requestVoid { helper, reply in helper.deleteDefaultRoute(gatewayIP: gatewayIP, reply: reply) }
    }

    func deleteHostRoute(ip: String) async throws {
        try await requestVoid { helper, reply in helper.deleteHostRoute(ip: ip, reply: reply) }
    }
}

/// Resumes a continuation at most once. XPC delivers either a reply or an
/// error for a call, but a connection tearing down mid-call can race the two;
/// resuming a checked continuation twice traps.
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

/// The app side of the reverse XPC interface: receives pushed session
/// changes from the helper.
final class SessionObserverEndpoint: NSObject, SessionObserverProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var onStatus: (@Sendable (SessionStatus) -> Void)?
    private var onConnectionLost: (@Sendable () -> Void)?

    func set(
        onStatus: @escaping @Sendable (SessionStatus) -> Void,
        onConnectionLost: @escaping @Sendable () -> Void
    ) {
        lock.withLock {
            self.onStatus = onStatus
            self.onConnectionLost = onConnectionLost
        }
    }

    func sessionStatusChanged(_ status: Data) {
        guard let decoded = SessionStatus.decode(status) else { return }
        lock.withLock { onStatus }?(decoded)
    }

    func connectionLost() {
        lock.withLock { onConnectionLost }?()
    }
}
