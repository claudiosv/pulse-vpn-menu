import Foundation
import PulseVPNHelperProtocol

/// Implements the privileged operations themselves. This process already
/// runs as root (launchd started it that way per the LaunchDaemon plist),
/// so there's no `sudo`, no shell, no quoting/escaping anywhere here —
/// every operation is a direct `Process` spawn or libc `kill()` call with a
/// real argv array or scalar arguments.
final class HelperService: NSObject, PrivilegedHelperProtocol {
    private let lock = NSLock()
    private var tracked: [Int32: Process] = [:]

    func launchOpenConnect(argv: [String], logPath: String, reply: @escaping (Int32, NSError?) -> Void) {
        guard !argv.isEmpty else {
            reply(0, Self.error("Empty argv"))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardInput = FileHandle.nullDevice
        // launchd gives daemons a minimal PATH (confirmed via `launchctl
        // print`: just /usr/bin:/bin:/usr/sbin:/sbin) that doesn't include
        // Homebrew — openconnect execs the vpnc-script (`-s <script>`, e.g.
        // "vpn-slice ...") via /bin/sh inheriting this same environment, so
        // without augmenting PATH here the script fails with
        // "command not found" even though the connection itself succeeds.
        process.environment = [
            "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]

        guard let logFile = CappedLogFile(path: logPath) else {
            reply(0, Self.error("Could not open \(logPath) for writing"))
            return
        }

        // openconnect never timestamps its own output, so stdout/stderr are
        // piped through here (rather than redirected straight to the log
        // file) and prefixed with a human-readable timestamp per line,
        // matching the app's own log (LogStore.append -> app.log). Both
        // streams' writes are serialized onto one queue since they share a
        // single destination `CappedLogFile`, which also keeps the file
        // from growing unbounded on a long-lived, idle-but-still-polled
        // connection.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let logQueue = DispatchQueue(label: "com.claudiosv.pulse-vpn-menu.helper.logwriter")
        let stdoutWriter = TimestampingLogWriter(logFile: logFile)
        let stderrWriter = TimestampingLogWriter(logFile: logFile)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            logQueue.async { stdoutWriter.consume(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            logQueue.async { stderrWriter.consume(data) }
        }

        process.terminationHandler = { _ in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            logQueue.async {
                stdoutWriter.flush()
                stderrWriter.flush()
                logFile.close()
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            reply(0, error as NSError)
            return
        }

        let pid = process.processIdentifier
        lock.lock()
        tracked[pid] = process
        lock.unlock()
        reply(pid, nil)
    }

    func processStatus(pid: Int32, reply: @escaping (Bool, Bool, Int32) -> Void) {
        lock.lock()
        let process = tracked[pid]
        lock.unlock()

        guard let process else {
            reply(false, false, 0)
            return
        }
        if process.isRunning {
            reply(true, true, 0)
        } else {
            reply(true, false, process.terminationStatus)
        }
    }

    func terminateOpenConnect(pid: Int32, reply: @escaping (NSError?) -> Void) {
        sendSignal(SIGTERM, to: pid, reply: reply)
    }

    func requestStatsUpdate(pid: Int32, reply: @escaping (NSError?) -> Void) {
        sendSignal(SIGUSR1, to: pid, reply: reply)
    }

    func requestReconnect(pid: Int32, reply: @escaping (NSError?) -> Void) {
        sendSignal(SIGUSR2, to: pid, reply: reply)
    }

    private func sendSignal(_ signal: Int32, to pid: Int32, reply: @escaping (NSError?) -> Void) {
        if kill(pid, signal) != 0 {
            reply(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        } else {
            reply(nil)
        }
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
