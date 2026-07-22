import Foundation

/// Categorizes the openconnect log lines that repeat verbatim-shaped (same
/// fields, new values each time) on every SIGUSR1 stats dump — as opposed
/// to one-time events that only ever appear once per connection. Shared
/// between `StatsHistory` (which needs to recognize and parse every single
/// occurrence, to keep the traffic graph and session info current) and
/// `LogStore` (which, when `AppSettings.hideRepeatedStatsLines` is on, only
/// wants to *display* the first occurrence of each kind and hide the rest).
enum RepeatableStatsLine: Hashable {
    case configured
    case sessionExpiry
    case rxTx
    case sslCiphersuite
}

enum StatsLineClassifier {
    static let rxTxRegex = try! NSRegularExpression(
        pattern: #"RX:\s*(\d+) packets? \((\d+) B\);\s*TX:\s*(\d+) packets? \((\d+) B\)"#
    )
    static let configuredRegex = try! NSRegularExpression(
        pattern: #"Configured as (\S+), with (.+)"#
    )
    static let expiryRegex = try! NSRegularExpression(
        pattern: #"Session authentication will expire at (.+)"#
    )
    static let ciphersuiteRegex = try! NSRegularExpression(
        pattern: #"SSL ciphersuite: (.+)"#
    )

    static func classify(_ line: String) -> RepeatableStatsLine? {
        let range = NSRange(line.startIndex..., in: line)
        if rxTxRegex.firstMatch(in: line, range: range) != nil { return .rxTx }
        if configuredRegex.firstMatch(in: line, range: range) != nil { return .configured }
        if expiryRegex.firstMatch(in: line, range: range) != nil { return .sessionExpiry }
        if ciphersuiteRegex.firstMatch(in: line, range: range) != nil { return .sslCiphersuite }
        return nil
    }
}
