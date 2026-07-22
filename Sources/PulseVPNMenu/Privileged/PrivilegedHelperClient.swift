import CryptoKit
import Foundation
import PulseVPNHelperProtocol
import ServiceManagement

enum PrivilegedHelperError: Error, CustomStringConvertible {
    case notEnabled(SMAppService.Status)
    case connectionUnavailable
    case helperError(NSError)

    var description: String {
        switch self {
        case .notEnabled(let status): return "Privileged helper is not enabled (status: \(status))."
        case .connectionUnavailable: return "Could not reach the privileged helper."
        case .helperError(let error): return error.localizedDescription
        }
    }
}

/// Talks to the privileged helper daemon over XPC. Replaces
/// `PrivilegedRunner`/`SudoersInstaller`/`ShellQuoting` entirely: no more
/// `sudo`/`osascript`, no shell strings to quote, no `waitForChildPid`
/// process-tree walking (the helper spawns openconnect itself and reports
/// its real PID synchronously).
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
                        try? await Task.sleep(nanoseconds: 500_000_000)
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
        newConnection.setCodeSigningRequirement(PrivilegedHelperConstants.helperRequirement)
        newConnection.invalidationHandler = { [weak self] in self?.clearConnection() }
        newConnection.interruptionHandler = { [weak self] in self?.clearConnection() }
        newConnection.activate()
        connection = newConnection
        return newConnection
    }

    private func clearConnection() {
        lock.lock()
        connection = nil
        lock.unlock()
    }

    private func proxy() throws -> PrivilegedHelperProtocol {
        guard status == .enabled else {
            throw PrivilegedHelperError.notEnabled(status)
        }
        let c = connectionOrMake()
        guard let proxy = c.remoteObjectProxyWithErrorHandler({ _ in }) as? PrivilegedHelperProtocol else {
            throw PrivilegedHelperError.connectionUnavailable
        }
        return proxy
    }

    // MARK: - Typed operations (one async wrapper per protocol method)

    func launchOpenConnect(argv: [String], logFile: URL) async throws -> Int32 {
        let helper = try proxy()
        return try await withCheckedThrowingContinuation { continuation in
            helper.launchOpenConnect(argv: argv, logPath: logFile.path) { pid, error in
                if let error {
                    continuation.resume(throwing: PrivilegedHelperError.helperError(error))
                } else {
                    continuation.resume(returning: pid)
                }
            }
        }
    }

    func processStatus(pid: Int32) async throws -> (known: Bool, running: Bool, exitCode: Int32) {
        let helper = try proxy()
        return await withCheckedContinuation { continuation in
            helper.processStatus(pid: pid) { known, running, exitCode in
                continuation.resume(returning: (known, running, exitCode))
            }
        }
    }

    func terminateOpenConnect(pid: Int32) async throws {
        try await call(pid: pid) { helper, pid, reply in helper.terminateOpenConnect(pid: pid, reply: reply) }
    }

    func requestStatsUpdate(pid: Int32) async throws {
        try await call(pid: pid) { helper, pid, reply in helper.requestStatsUpdate(pid: pid, reply: reply) }
    }

    func requestReconnect(pid: Int32) async throws {
        try await call(pid: pid) { helper, pid, reply in helper.requestReconnect(pid: pid, reply: reply) }
    }

    func setDefaultRoute(gatewayIP: String) async throws {
        try await call(argument: gatewayIP) { helper, ip, reply in helper.setDefaultRoute(gatewayIP: ip, reply: reply) }
    }

    func addDefaultRoute(gatewayIP: String) async throws {
        try await call(argument: gatewayIP) { helper, ip, reply in helper.addDefaultRoute(gatewayIP: ip, reply: reply) }
    }

    func deleteDefaultRoute(gatewayIP: String) async throws {
        try await call(argument: gatewayIP) { helper, ip, reply in helper.deleteDefaultRoute(gatewayIP: ip, reply: reply) }
    }

    func deleteHostRoute(ip: String) async throws {
        try await call(argument: ip) { helper, ip, reply in helper.deleteHostRoute(ip: ip, reply: reply) }
    }

    // MARK: - Shared plumbing for the common "pid in, error out" and
    // "String in, error out" method shapes.

    private func call(
        pid: Int32,
        _ body: (PrivilegedHelperProtocol, Int32, @escaping (NSError?) -> Void) -> Void
    ) async throws {
        let helper = try proxy()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            body(helper, pid) { error in
                if let error {
                    continuation.resume(throwing: PrivilegedHelperError.helperError(error))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func call(
        argument: String,
        _ body: (PrivilegedHelperProtocol, String, @escaping (NSError?) -> Void) -> Void
    ) async throws {
        let helper = try proxy()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            body(helper, argument) { error in
                if let error {
                    continuation.resume(throwing: PrivilegedHelperError.helperError(error))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
