import Foundation
import Network
import NetworkExtension
import OpenConnectKit
import OpenConnectTunnelProtocol
import os

/// The packet tunnel provider: one instance per tunnel start, created by the
/// system inside the (sandboxed, root) system extension. It runs the
/// libopenconnect session in-process, turns what the server assigns into
/// network settings the system applies, and moves packets between the
/// system's packet flow and libopenconnect.
///
/// The Objective-C name is what `NEProviderClasses` in the extension's
/// Info.plist refers to.
@objc(OpenConnectPacketTunnelProvider)
public final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let session = TunnelSession()
    private let logger = Logger(subsystem: TunnelConstants.extensionBundleIdentifier, category: "provider")

    private let lock = NSLock()
    private var bridge: PacketBridge?
    private var startCompletion: ((Error?) -> Void)?
    private var stopCompletion: (() -> Void)?

    /// Signalled when the app has been sent the session's final status.
    private let finalStatusCollected = DispatchSemaphore(value: 0)

    /// How long a finished session waits for the app to collect its final
    /// status and log before the provider goes away (after which nothing can
    /// be asked of it). Costs nothing when the app polls promptly.
    private static let finalStatusGrace: TimeInterval = 1.5

    /// Set while a start without a cookie waits for the app to send one.
    private var pendingConfiguration: TunnelConfiguration?

    private var pathMonitor: NWPathMonitor?
    private var addressWatcher: NetworkAddressWatcher?
    private var lastPathSignature: String?
    /// Network changes before this time are the tunnel's own setup.
    private var settleUntil: Date?
    private static let settleTime: TimeInterval = 5
    private var pendingReconnect: DispatchWorkItem?

    /// Network changes tend to arrive in bursts; reconnect once things settle.
    private static let reconnectDelay: TimeInterval = 2

    // MARK: - Start

    public override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let saved = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        guard let configuration = TunnelConfiguration(providerConfiguration: saved) else {
            logger.error("No readable TunnelConfiguration in the VPN configuration")
            completionHandler(Self.error(
                EINVAL, "This VPN configuration can't be read. Open OpenConnect Menu and save the connection again."))
            return
        }

        session.onChange = { Self.postStatusChanged() }
        lock.withLock { startCompletion = completionHandler }

        // The login cookie arrives in the start options, so a start from
        // System Settings (or anything else that isn't the app) has none.
        // Stay in "Connecting" and say so through the status: the app, if it
        // is running, signs in and sends the cookie (`.login`). If it never
        // does, give up after `loginWait`.
        guard let cookie = options?[TunnelConstants.cookieOptionKey] as? String, !cookie.isEmpty else {
            logger.notice("Started without a login cookie; waiting for the app")
            lock.withLock { pendingConfiguration = configuration }
            session.awaitLogin()
            DispatchQueue.global().asyncAfter(deadline: .now() + TunnelConstants.loginWait) { [self] in
                guard lock.withLock({ take(&pendingConfiguration) }) != nil else { return }
                session.fail(
                    exitCode: TunnelConstants.needsLoginExitCode,
                    message: "Sign-in required: OpenConnect Menu did not sign in. Open it and connect again.")
                sessionEnded(TunnelConstants.needsLoginExitCode)
            }
            return
        }
        beginSession(cookie: cookie, configuration: configuration)
    }

    /// Sends a cookie to a start that was waiting for one.
    private func deliverLogin(cookie: String) {
        guard let configuration = lock.withLock({ take(&pendingConfiguration) }) else { return }
        session.log.append("Signed in by the app\n")
        beginSession(cookie: cookie, configuration: configuration)
    }

    private func beginSession(cookie: String, configuration: TunnelConfiguration) {
        logger.notice("Starting session for profile \(configuration.profileID.uuidString, privacy: .public)")
        session.start(
            url: configuration.vpnURL,
            cookie: cookie,
            pinnedCertHash: configuration.pinnedCertHash,
            verbose: configuration.verbose,
            configureTunnel: { [self] server in
                configureTunnel(server: server, configuration: configuration)
            },
            onExit: { [self] rc in sessionEnded(rc) }
        )
        startPathMonitor()
    }

    // MARK: - Reconnect on wake and network change

    public override func wake() {
        scheduleReconnect(because: "the Mac woke from sleep")
    }

    /// Watches the physical network (not the tunnel's own interface) and asks
    /// for a reconnect when the usable path changes, e.g. a Wi-Fi switch.
    private func startPathMonitor() {
        let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other])
        monitor.pathUpdateHandler = { [weak self] path in self?.evaluate(path) }
        monitor.start(queue: .global(qos: .utility))

        // `NWPath` doesn't carry the local address, so a new address on the
        // same interface and gateway (a DHCP renewal) is caught through the
        // system configuration store instead.
        let watcher = NetworkAddressWatcher { [weak self] in
            guard let self, let path = lock.withLock({ pathMonitor?.currentPath }) else { return }
            evaluate(path)
        }
        if watcher == nil {
            session.log.append("Address changes on the same network won't be noticed (system configuration store unavailable)\n")
        }
        lock.withLock {
            pathMonitor?.cancel()
            addressWatcher?.stop()
            pathMonitor = monitor
            addressWatcher = watcher
            lastPathSignature = nil
        }
    }

    private func stopPathMonitor() {
        lock.withLock {
            pathMonitor?.cancel()
            pathMonitor = nil
            addressWatcher?.stop()
            addressWatcher = nil
            pendingReconnect?.cancel()
            pendingReconnect = nil
        }
    }

    /// Compares the network now with the last one seen and schedules a
    /// reconnect if it changed to something usable.
    private func evaluate(_ path: NWPath) {
        let signature = Self.signature(of: path)
        let previous = lock.withLock { () -> String? in
            defer { lastPathSignature = signature }
            // Applying the tunnel's own routes and DNS changes what the system
            // reports; that is not the user's network changing, so whatever
            // is seen just after setup becomes the new baseline.
            if let settleUntil, Date() < settleUntil { return nil }
            return lastPathSignature
        }
        // The first evaluation is the baseline; coming back from "no
        // network", or moving to another interface, gateway or address, is
        // a change.
        guard let previous, previous != signature, path.status == .satisfied else { return }
        scheduleReconnect(because: "the network changed (\(previous) -> \(signature))")
    }

    private static func signature(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces.map(\.name).joined(separator: ",")
        let gateways = path.gateways.map { "\($0)" }.joined(separator: ",")
        return "\(path.status)|\(interfaces)|\(gateways)|\(NetworkAddresses.snapshot())"
    }

    private func scheduleReconnect(because reason: String) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, session.isRunning else { return }
            session.log.append("Reconnecting: \(reason)\n")
            session.requestReconnect()
        }
        lock.withLock {
            pendingReconnect?.cancel()
            pendingReconnect = work
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.reconnectDelay, execute: work)
    }

    /// On the session thread, once the server has assigned addresses: applies
    /// the network settings and returns the fd libopenconnect exchanges
    /// packets on (or a negative errno).
    private func configureTunnel(server: OpenConnectNetworkConfig, configuration: TunnelConfiguration) -> Int32 {
        let plan: TunnelPlan
        do {
            plan = try TunnelPlan.make(
                server: server,
                routing: configuration.routing,
                dns: configuration.dns,
                fallbackRemoteAddress: URL(string: configuration.vpnURL)?.host ?? "0.0.0.0")
        } catch {
            session.log.append("\(error.localizedDescription)\n")
            return -EINVAL
        }
        session.log.append(Self.describe(plan) + "\n")

        let applied = DispatchSemaphore(value: 0)
        let failure = Box<Error?>(nil)
        setTunnelNetworkSettings(plan.networkSettings()) { error in
            failure.value = error
            applied.signal()
        }
        guard applied.wait(timeout: .now() + 30) == .success else {
            session.log.append("Timed out applying the tunnel network settings\n")
            return -ETIMEDOUT
        }
        if let error = failure.value {
            session.log.append("The system rejected the tunnel network settings: \(error.localizedDescription)\n")
            return -EIO
        }

        lock.withLock { settleUntil = Date().addingTimeInterval(Self.settleTime) }

        do {
            nonisolated(unsafe) let flow = packetFlow
            let bridge = try PacketBridge(
                readPackets: { completion in flow.readPackets(completionHandler: completion) },
                writePackets: { packets, protocols in _ = flow.writePackets(packets, withProtocols: protocols) }
            )
            lock.withLock { self.bridge = bridge }
            bridge.start()
            session.setTunnelDetails(
                interfaceName: plan.ipv4.flatMap { interfaceName(forIPv4: $0.address) },
                dnsServers: plan.dnsInUse ? plan.dnsServers : [],
                dnsDomains: plan.matchDomains
            )
            // The system now shows the tunnel as connected.
            lock.withLock { take(&startCompletion) }?(nil)
            return bridge.libraryFD
        } catch {
            session.log.append("\(error.localizedDescription)\n")
            return -EIO
        }
    }

    // MARK: - End

    /// After the session has ended for any reason, on the thread it ended on.
    private func sessionEnded(_ rc: Int32) {
        logger.notice("Session ended with \(rc)")
        stopPathMonitor()
        lock.withLock { take(&bridge) }?.stop()
        Self.postStatusChanged()

        // Once this returns to the system the provider is torn down and the
        // app can no longer ask why; let it collect the answer first.
        _ = finalStatusCollected.wait(timeout: .now() + Self.finalStatusGrace)

        let (start, stop) = lock.withLock { (take(&startCompletion), take(&stopCompletion)) }
        let error: Error? = rc == -EINTR ? nil : Self.error(-rc, Self.reason(for: rc, status: session.status()))
        if start == nil, stop == nil {
            // Up and running until now: tell the system the tunnel is gone.
            cancelTunnelWithError(error)
            return
        }
        start?(error ?? Self.error(EINTR, "The connection attempt was cancelled."))
        stop?()
    }

    public override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.notice("Stop requested, reason \(reason.rawValue)")
        // Still waiting for the app's cookie: nothing runs, so just give up.
        let waiting: (() -> Void)? = lock.withLock {
            guard take(&pendingConfiguration) != nil else { return nil }
            let start = take(&startCompletion)
            return { start?(Self.error(EINTR, "The connection attempt was cancelled.")) }
        }
        if let waiting {
            waiting()
            completionHandler()
            return
        }
        guard session.isRunning else {
            completionHandler()
            return
        }
        session.log.append("Disconnect requested\n")
        lock.withLock { stopCompletion = completionHandler }
        // Logs the session off; `sessionEnded` then calls the completion.
        session.cancel()
        // A session that can't be told to stop (e.g. still resolving the
        // server) must not hold the system's stop forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [self] in
            lock.withLock { take(&stopCompletion) }?()
        }
    }

    // MARK: - App messages

    public override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let request = TunnelRequest.decode(messageData) else {
            completionHandler?(nil)
            return
        }
        switch request.operation {
        case .reconnect:
            session.log.append("Reconnect requested\n")
            session.requestReconnect()
        case .login:
            if let cookie = request.cookie, !cookie.isEmpty { deliverLogin(cookie: cookie) }
        case .poll:
            break
        }
        let status = session.status()
        let (lines, last) = session.log.lines(after: request.afterLog)
        completionHandler?(TunnelReply(status: status, logLines: lines, lastLogSequence: last).encoded())
        if status.state == .exited {
            finalStatusCollected.signal()
        }
    }

    // MARK: - Helpers

    private static func postStatusChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(TunnelConstants.statusChangedNotification as CFString),
            nil, nil, true)
    }

    private static func error(_ code: Int32, _ message: String) -> NSError {
        NSError(
            domain: TunnelConstants.errorDomain, code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func reason(for rc: Int32, status: SessionStatus) -> String {
        if let failure = status.certFailure {
            return "The server's certificate is not trusted (\(failure.reason)). Connect from OpenConnect Menu to review it."
        }
        switch rc {
        case TunnelConstants.needsLoginExitCode:
            return "Sign-in required. Open OpenConnect Menu to connect."
        case -EPERM:
            return "The server rejected the login, or it has expired."
        case -EPIPE:
            return "The server ended the session."
        default:
            return "The VPN session ended: \(String(cString: strerror(-rc)))."
        }
    }

    private static func describe(_ plan: TunnelPlan) -> String {
        var routes: [String] = []
        if plan.isFullTunnel {
            routes = ["all traffic"]
        } else {
            routes += plan.ipv4?.included.map { "\($0.address)/\($0.mask)" } ?? []
            routes += plan.ipv6?.included.map { "\($0.address)/\($0.prefixLength)" } ?? []
        }
        var text = "Routing through the tunnel: \(routes.isEmpty ? "nothing" : routes.joined(separator: ", "))"
        if !plan.dnsServers.isEmpty {
            let scope = plan.matchDomains.map { " for \($0.joined(separator: ", "))" } ?? (plan.isFullTunnel ? "" : " (unused: no domains to match)")
            text += "; DNS \(plan.dnsServers.joined(separator: ", "))\(scope)"
        }
        return text
    }
}

/// Returns `value` and leaves nil behind (call with the owning lock held).
private func take<T>(_ value: inout T?) -> T? {
    defer { value = nil }
    return value
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
