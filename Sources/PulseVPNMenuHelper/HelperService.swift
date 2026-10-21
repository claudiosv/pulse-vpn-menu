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

    func startSession(
        url: String,
        cookie: String,
        vpncScript: String?,
        pinnedCertHash: String?,
        logPath: String,
        reply: @escaping (NSError?) -> Void
    ) {
        do {
            try session.start(
                url: url,
                cookie: cookie,
                vpncScript: vpncScript,
                pinnedCertHash: pinnedCertHash,
                logPath: logPath
            )
            reply(nil)
        } catch {
            reply(Self.error(error.localizedDescription))
        }
    }

    func sessionStatus(reply: @escaping (Int32, Int32, Double, String?, String?, Data?) -> Void) {
        let s = session.currentStatus()
        reply(s.state.rawValue, s.exitCode, s.startedAt, s.certFailureReason, s.certHash, session.snapshotData())
    }

    func pollStats(reply: @escaping (Data?) -> Void) {
        reply(session.pollStatsData())
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
        runRoute(["change", "default", gatewayIP], reply: reply)
    }

    func addDefaultRoute(gatewayIP: String, reply: @escaping (NSError?) -> Void) {
        runRoute(["add", "default", gatewayIP], reply: reply)
    }

    func deleteDefaultRoute(gatewayIP: String, reply: @escaping (NSError?) -> Void) {
        runRoute(["delete", "default", gatewayIP], reply: reply)
    }

    func deleteHostRoute(ip: String, reply: @escaping (NSError?) -> Void) {
        runRoute(["-n", "delete", ip], reply: reply)
    }

    private func runRoute(_ arguments: [String], reply: @escaping (NSError?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = arguments
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
