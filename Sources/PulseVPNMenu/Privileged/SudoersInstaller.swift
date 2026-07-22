import Foundation

/// Installs a narrowly-scoped `/etc/sudoers.d` rule granting the current
/// user passwordless `sudo` for exactly the commands this app needs to run
/// as root (launching openconnect, the specific route/kill invocations
/// `RouteManager`/`OpenConnectController` use) — nothing broader.
///
/// Without this, every privileged action goes through
/// `osascript ... with administrator privileges`, which macOS only caches
/// for a few minutes, so anything but very frequent use re-prompts for a
/// password. Installing this rule is a one-time action (itself gated by a
/// single admin-privileges prompt) after which `PrivilegedRunner` talks to
/// `sudo` directly and never prompts again for these specific commands.
///
/// Tradeoff, by design: these are broad command+wildcard-args grants
/// (`<openconnect> *`, `/sbin/route change default *`, etc.), not scoped to
/// this app's own process — any locally-running process running as this
/// user could also invoke them without a password. That's the deliberate
/// cost of the "narrow sudoers" approach the user chose over a full
/// SMAppService/XPC privileged-helper tool.
enum SudoersInstaller {
    /// No dots allowed: sudo's `@includedir` (`man sudoers`) silently
    /// *skips* any file in sudoers.d whose name contains a `.` or ends in
    /// `~` — reserved for editor/package-manager backup files. An earlier
    /// version of this used a dotted bundle-id-style name
    /// (`com.claudiosv.pulse-vpn-menu`) and was completely ignored as a
    /// result — installed successfully, validated fine, correct
    /// permissions, and yet granted nothing at all.
    private static let sudoersFile = URL(fileURLWithPath: "/etc/sudoers.d/pulse-vpn-menu")

    /// The previous, incorrectly-named (and silently ignored) file, if a
    /// prior run left it behind — cleaned up on install.
    private static let legacyDottedSudoersFile = URL(fileURLWithPath: "/etc/sudoers.d/com.claudiosv.pulse-vpn-menu")

    private static let routePath = "/sbin/route"
    private static let killPath = "/bin/kill"

    /// The rule content for the *currently resolved* openconnect path. If
    /// openconnect gets reinstalled somewhere else later, `isInstalled()`
    /// will notice the mismatch and `ensureInstalled()` will refresh it.
    private static func desiredContents() -> String {
        let user = NSUserName()
        let openconnectPath = OpenConnectController.findOpenConnectPath()
        return """
        # Managed by Pulse VPN Menu. Grants passwordless sudo for exactly
        # the commands this app runs as root — safe to delete; the app
        # will fall back to prompting for a password per action.
        Defaults:\(user) !requiretty
        \(user) ALL=(root) NOPASSWD: \(openconnectPath) *
        \(user) ALL=(root) NOPASSWD: \(routePath) change default *
        \(user) ALL=(root) NOPASSWD: \(routePath) delete default *
        \(user) ALL=(root) NOPASSWD: \(routePath) add default *
        \(user) ALL=(root) NOPASSWD: \(routePath) -n delete *
        \(user) ALL=(root) NOPASSWD: \(killPath) -TERM *
        \(user) ALL=(root) NOPASSWD: \(killPath) -USR1 *
        \(user) ALL=(root) NOPASSWD: \(killPath) -USR2 *

        """
    }

    /// True if the rule is already installed and up to date (matches what
    /// we'd generate right now — catches a stale openconnect path).
    static func isInstalled() -> Bool {
        guard let existing = try? String(contentsOf: sudoersFile, encoding: .utf8) else { return false }
        return existing == desiredContents()
    }

    enum InstallError: Error, CustomStringConvertible {
        case invalidSyntax(String)
        case installFailed(String)

        var description: String {
            switch self {
            case .invalidSyntax(let detail): return "Generated sudoers rule failed validation: \(detail)"
            case .installFailed(let detail): return "Failed to install sudoers rule: \(detail)"
            }
        }
    }

    /// Validates the generated rule with `visudo -c` (so a bug here can
    /// never corrupt the system's sudo configuration) and, only if valid,
    /// writes it into place. Copy/chown/chmod (and removing any leftover
    /// legacy dotted-name file) run as a single administrator-privileges
    /// batch — one password prompt total, not one per step.
    static func install() async throws {
        let contents = desiredContents()
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-vpn-menu-sudoers-\(UUID().uuidString)")
        try contents.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        try await validate(tempFile: tempFile)

        let runner = PrivilegedRunner()
        do {
            try await runner.runBatch([
                ["/bin/rm", "-f", legacyDottedSudoersFile.path],
                ["/bin/cp", tempFile.path, sudoersFile.path],
                ["/usr/sbin/chown", "root:wheel", sudoersFile.path],
                // World-readable, root-writable only: the unprivileged app
                // itself needs to read this to implement `isInstalled()`,
                // and the current user isn't necessarily in the "wheel"
                // group (checked: not by default on this machine) — 0440
                // would leave the file completely unreadable to the app,
                // making it think the rule was never installed. Read access
                // to sudo *policy text* isn't sensitive; only write access
                // is, and that stays root-only regardless.
                ["/bin/chmod", "444", sudoersFile.path],
            ])
        } catch {
            throw InstallError.installFailed(String(describing: error))
        }
    }

    /// Removes the rule, reverting to always-prompt behavior.
    static func uninstall() async throws {
        let runner = PrivilegedRunner()
        try await runner.run(["/bin/rm", "-f", sudoersFile.path])
    }

    private static func validate(tempFile: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        process.arguments = ["-c", "-f", tempFile.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(decoding: data, as: UTF8.self)
                    continuation.resume(throwing: InstallError.invalidSyntax(message))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: InstallError.invalidSyntax(error.localizedDescription))
            }
        }
    }
}
