import Foundation

enum PrivilegedRunnerError: Error, CustomStringConvertible {
    case osascriptLaunchFailed(String)
    case sudoLaunchFailed(String)
    case nonZeroExit(status: Int32, stderr: String)

    var description: String {
        switch self {
        case .osascriptLaunchFailed(let reason):
            return "Failed to launch osascript: \(reason)"
        case .sudoLaunchFailed(let reason):
            return "Failed to launch via sudo: \(reason)"
        case .nonZeroExit(let status, let stderr):
            return "Privileged command exited with status \(status): \(stderr)"
        }
    }
}

/// Runs commands as root. Two modes:
///
/// - **sudo** (used once `SudoersInstaller.isInstalled()` is true): each
///   command is run directly as `sudo -n <argv...>` — a plain argv array,
///   no shell involved. This is required, not just simpler: the installed
///   sudoers rule only grants NOPASSWD for exact command+args patterns
///   (`<openconnect> *`, `/sbin/route change default *`, etc.), so running
///   an arbitrary shell string (`sudo sh -c "..."`) would need a `sh -c *`
///   grant — which is unrestricted root shell access, defeating the whole
///   point of a narrowly-scoped rule.
/// - **osascript** (fallback, when the sudoers rule isn't installed): the
///   native macOS "administrator privileges" dialog
///   (`osascript -e 'do shell script "..." with administrator
///   privileges'`), same mechanism the Python app's `OsascriptRunner` uses.
///   `do shell script` buffers all output until its command exits, so
///   long-running commands (openconnect itself) are launched via
///   `runOpenConnectBackground`, which backgrounds them inside a nested
///   shell so the outer call returns almost instantly while the real
///   process keeps running and streams output to a log file instead.
///
/// Holds no mutable state (every method builds and runs a fresh `Process`),
/// so it's safe to hand across the actor boundary into the detached `Task`
/// each call uses to avoid blocking its caller's actor/thread.
final class PrivilegedRunner: @unchecked Sendable {
    /// Re-checked on every access (a cheap file read), not cached at init.
    /// `SudoersInstaller.install()` can succeed partway through the very
    /// same `connect()` call that created this `PrivilegedRunner` — caching
    /// this as a stored `let` meant every action for the rest of that
    /// session (in particular the stats timer's `kill -USR1` every 5s) kept
    /// using the old per-call password-prompt path even after the
    /// passwordless rule was already installed and ready to use.
    var sudoAvailable: Bool {
        SudoersInstaller.isInstalled()
    }

    /// Runs a single command with root privileges and waits for it to
    /// complete. Suitable for short-lived commands: `route`, `kill`, `rm`,
    /// etc. `async` so the wait (which, in osascript mode, includes however
    /// long the user takes to respond to the password dialog) never blocks
    /// the caller's actor/thread — critical since callers run on
    /// `@MainActor` and a blocking wait there would freeze the entire UI.
    @discardableResult
    func run(_ argv: [String]) async throws -> (status: Int32, stdout: String) {
        try await runBatch([argv])
    }

    /// Runs several commands as root. In sudo mode, each runs as its own
    /// `sudo -n <argv>` call (no password prompts, nothing to batch — nomes
    /// to save by combining them). In osascript mode, they're joined with
    /// `; ` into one administrator-privileges dialog (one password prompt
    /// for the whole batch), matching Python's `OsascriptRunner.run_script`.
    @discardableResult
    func runBatch(_ commands: [[String]]) async throws -> (status: Int32, stdout: String) {
        if sudoAvailable {
            var last: (status: Int32, stdout: String) = (0, "")
            for command in commands {
                last = try await runViaSudo(command)
            }
            return last
        }
        let shell = commands.map(ShellQuoting.posixSingleQuoteJoin).joined(separator: "; ")
        return try await runViaOsascript(shellCommand: shell)
    }

    /// Launches openconnect as root. In sudo mode, this is a direct,
    /// long-lived `Process` (`sudo -n <openconnect> <args...>`) the caller
    /// keeps a handle to — no shell, no pidfile/exitfile polling needed:
    /// `process.processIdentifier` is openconnect's real PID (`sudo` execs
    /// the target in place rather than forking, so the PID doesn't change),
    /// and `process.isRunning`/`process.terminationStatus` track its exit
    /// directly. In osascript mode, falls back to the detached
    /// pidfile/exitfile scheme (`runOpenConnectBackground`).
    func launchOpenConnectViaSudo(argv: [String], logFile: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n"] + argv
        process.standardInput = FileHandle.nullDevice

        guard let logHandle = FileHandle(forWritingAtPath: logFile.path) else {
            throw PrivilegedRunnerError.sudoLaunchFailed("Could not open \(logFile.path) for writing")
        }
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            throw PrivilegedRunnerError.sudoLaunchFailed(error.localizedDescription)
        }
        return process
    }

    /// osascript-mode fallback: launches `argv` (openconnect) as root,
    /// detached and backgrounded, so this call returns almost immediately
    /// instead of blocking for the life of the VPN connection.
    /// openconnect's stdout/stderr are redirected into `logFile`; its real
    /// PID is written to `pidFile` as soon as it starts; its eventual exit
    /// code is written to `exitFile` once it terminates. Callers poll
    /// `pidFile`/`exitFile` afterward.
    func runOpenConnectBackground(argv: [String], logFile: URL, pidFile: URL, exitFile: URL) async throws {
        let quotedArgv = ShellQuoting.posixSingleQuoteJoin(argv)
        let quotedLog = ShellQuoting.posixSingleQuote(logFile.path)
        let quotedPid = ShellQuoting.posixSingleQuote(pidFile.path)
        let quotedExit = ShellQuoting.posixSingleQuote(exitFile.path)

        // Inner shell: exec's openconnect in the background within itself
        // (so $! is openconnect's own PID), records the PID, waits on it
        // (blocking only this already-backgrounded inner shell), then
        // records the real exit code.
        let inner = "\(quotedArgv) > \(quotedLog) 2>&1 < /dev/null & echo $! > \(quotedPid); wait; echo $? > \(quotedExit)"

        // Outer command: backgrounds a wrapper `sh -c '<inner>'` and
        // returns immediately. Its OWN stdio must also be redirected away
        // from /dev/null — `do shell script` doesn't return until every
        // file descriptor connected to its output pipe is closed, and if
        // this outer shell (or anything it forks, including the "wait" at
        // the end of `inner`, which doesn't exit until the VPN session
        // ends) still holds that pipe open, "do shell script" hangs for the
        // entire life of the connection instead of returning immediately.
        let full = "sh -c " + ShellQuoting.posixSingleQuote(inner) + " > /dev/null 2>&1 < /dev/null &"

        _ = try await runViaOsascript(shellCommand: full)
    }

    private func runViaSudo(_ argv: [String]) async throws -> (status: Int32, stdout: String) {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n"] + argv

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                throw PrivilegedRunnerError.sudoLaunchFailed(error.localizedDescription)
            }
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(decoding: stdoutData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

            if process.terminationStatus != 0 {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(decoding: stderrData, as: UTF8.self)
                throw PrivilegedRunnerError.nonZeroExit(status: process.terminationStatus, stderr: stderr)
            }

            return (process.terminationStatus, stdout)
        }.value
    }

    private func runViaOsascript(shellCommand: String) async throws -> (status: Int32, stdout: String) {
        let escaped = ShellQuoting.appleScriptStringLiteralEscape(shellCommand)
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        return try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                throw PrivilegedRunnerError.osascriptLaunchFailed(error.localizedDescription)
            }
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(decoding: stdoutData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

            if process.terminationStatus != 0 {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(decoding: stderrData, as: UTF8.self)
                throw PrivilegedRunnerError.nonZeroExit(status: process.terminationStatus, stderr: stderr)
            }

            return (process.terminationStatus, stdout)
        }.value
    }
}
