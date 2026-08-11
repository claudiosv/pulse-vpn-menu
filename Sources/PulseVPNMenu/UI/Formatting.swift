import Foundation

/// Shared display formatting for traffic counters and session duration.
/// Lives in one place because the same numbers now appear in three
/// unrelated views (the menu's compact graph, the Status tab's stats card,
/// and the graph's own axis labels) and they should read identically.
///
/// Main-actor-isolated because `ByteCountFormatter` isn't `Sendable` and
/// this shared instance would otherwise be a concurrency-unsafe global;
/// every caller is a SwiftUI view body, which is already on the main actor.
@MainActor
enum Traffic {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter
    }()

    /// A cumulative byte counter, e.g. "1.4 MB".
    static func bytes(_ value: Double) -> String {
        byteFormatter.string(fromByteCount: Int64(max(0, value)))
    }

    /// A throughput reading, e.g. "128 KB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(bytesPerSecond) + "/s"
    }

    /// Session length as mm:ss, or h:mm:ss once past an hour.
    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
