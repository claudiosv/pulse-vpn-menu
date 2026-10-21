import Darwin
import Foundation

/// Checks on the arguments the (code-signed) app hands the root helper, so a
/// compromised or buggy client can't turn a narrow verb into a general
/// primitive. The vpnc-script is deliberately not covered: running a
/// user-configured script as root is how openconnect works.
enum RequestValidation {
    /// Only the app's own session log:
    /// `/Users/<user>/Library/Application Support/Pulse VPN Menu/Logs/current.log`,
    /// with no symlink anywhere in the path. The helper opens this file as
    /// root and trims it, so it must not be steerable at arbitrary files.
    static func sessionLogPath(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parts = url.pathComponents
        guard parts.count == 8,
              parts[0] == "/", parts[1] == "Users",
              Array(parts[3...]) == ["Library", "Application Support", "Pulse VPN Menu", "Logs", "current.log"]
        else { throw HelperError("Not the session log location: \(path)") }
        guard url.resolvingSymlinksInPath().path == url.path else {
            throw HelperError("The session log path must not involve symlinks")
        }
        return url.path
    }

    static func vpnURL(_ string: String) throws -> String {
        guard let url = URL(string: string), url.scheme == "https", url.host?.isEmpty == false else {
            throw HelperError("The VPN URL must be an https:// URL")
        }
        return string
    }

    /// A dotted-quad IPv4 address — the only thing the route calls take. (An
    /// argument starting with `-` would otherwise be read as an option.)
    static func ipv4(_ string: String) throws -> String {
        var address = in_addr()
        guard inet_pton(AF_INET, string, &address) == 1 else {
            throw HelperError("Not an IPv4 address: \(string)")
        }
        return string
    }
}
