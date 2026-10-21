import Foundation
import OpenConnectKit
import PulseVPNHelperProtocol

/// Implements the privileged operations themselves. This process already
/// runs as root (launchd started it that way per the LaunchDaemon plist),
/// so there's no `sudo`, no shell, no quoting/escaping anywhere here —
/// the VPN session runs in-process (`VPNSession`), and the route operations
/// are direct `Process` spawns with a real argv array.
final class HelperService: NSObject, PrivilegedHelperProtocol {
    private let session = VPNSession()
    /// App connections to push session changes to; the listener delegate
    /// adds each accepted connection.
    let observers = ObserverHub()

    override init() {
        super.init()
        let session = session, observers = observers
        session.onChange = {
            guard let data = session.currentStatus().encoded() else { return }
            observers.broadcast(data)
        }
    }

    func protocolVersion(reply: @escaping (Int) -> Void) {
        reply(PrivilegedHelperConstants.protocolVersion)
    }

    func startSession(
        url: String,
        cookie: String,
        vpncScript: String?,
        pinnedCertHash: String?,
        verbose: Bool,
        logPath: String,
        reply: @escaping (NSError?) -> Void
    ) {
        do {
            guard !cookie.isEmpty else { throw HelperError("No login cookie") }
            try session.start(
                url: try RequestValidation.vpnURL(url),
                cookie: cookie,
                vpncScript: vpncScript,
                pinnedCertHash: pinnedCertHash,
                verbose: verbose,
                logPath: try RequestValidation.sessionLogPath(logPath)
            )
            reply(nil)
        } catch {
            reply(Self.error(error.localizedDescription))
        }
    }

    func sessionStatus(reply: @escaping (Data) -> Void) {
        reply(session.currentStatus().encoded() ?? Data())
    }

    func stopSession(reply: @escaping (NSError?) -> Void) {
        command(reply) { $0.cancel() }
    }

    func requestReconnect(reply: @escaping (NSError?) -> Void) {
        command(reply) { $0.requestReconnect() }
    }

    private func command(_ reply: (NSError?) -> Void, _ body: (EmbeddedOpenConnect) -> Void) {
        guard let running = session.running else {
            reply(Self.error("No VPN session is running"))
            return
        }
        body(running)
        reply(nil)
    }

    func setDefaultRoute(gatewayIP: String, reply: @escaping (NSError?) -> Void) {
        runRoute(["change", "default"], address: gatewayIP, reply: reply)
    }

    func addDefaultRoute(gatewayIP: String, reply: @escaping (NSError?) -> Void) {
        runRoute(["add", "default"], address: gatewayIP, reply: reply)
    }

    func deleteDefaultRoute(gatewayIP: String, reply: @escaping (NSError?) -> Void) {
        runRoute(["delete", "default"], address: gatewayIP, reply: reply)
    }

    func deleteHostRoute(ip: String, reply: @escaping (NSError?) -> Void) {
        runRoute(["-n", "delete"], address: ip, reply: reply)
    }

    /// `arguments` plus the one address, which must be a plain IPv4 address.
    private func runRoute(_ arguments: [String], address: String, reply: @escaping (NSError?) -> Void) {
        let validated: String
        do {
            validated = try RequestValidation.ipv4(address)
        } catch {
            reply(Self.error(error.localizedDescription))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = arguments + [validated]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            reply(error as NSError)
            return
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
            reply(Self.error(message.isEmpty ? "route exited with status \(process.terminationStatus)" : message))
        } else {
            reply(nil)
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "PulseVPNMenuHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
