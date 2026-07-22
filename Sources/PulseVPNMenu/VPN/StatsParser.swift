import Foundation

/// One SIGUSR1 sample. Byte/packet counters are cumulative for the session.
/// Mirrors Python's `stats.py`'s `VpnStats`.
struct VpnStats: Equatable {
    var timestamp: Date
    var rxPackets: Int
    var rxBytes: Int
    var txPackets: Int
    var txBytes: Int
}

/// Parses openconnect's SIGUSR1 stats-dump lines and keeps a rolling
/// history, mirroring `stats.py`'s `StatsHistory`. Not actor/lock-guarded
/// like the Python version since it's only ever touched on the main actor
/// here (see `OpenConnectController`).
@MainActor
final class StatsHistory: ObservableObject {
    @Published private(set) var samples: [VpnStats] = []
    @Published private(set) var tunnelIP: String?
    @Published private(set) var tunnelStatus: String?
    @Published private(set) var sessionExpiry: String?
    @Published private(set) var sslCiphersuite: String?

    private let maxSamples = 4096

    private static let rxTxRegex = try! NSRegularExpression(
        pattern: #"RX:\s*(\d+) packets? \((\d+) B\);\s*TX:\s*(\d+) packets? \((\d+) B\)"#
    )
    private static let configuredRegex = try! NSRegularExpression(
        pattern: #"Configured as (\S+), with (.+)"#
    )
    private static let expiryRegex = try! NSRegularExpression(
        pattern: #"Session authentication will expire at (.+)"#
    )
    private static let ciphersuiteRegex = try! NSRegularExpression(
        pattern: #"SSL ciphersuite: (.+)"#
    )

    var current: VpnStats? { samples.last }

    /// Parses one line of openconnect output. Returns true if it was a
    /// recognized stats/session line (and was recorded), false otherwise.
    @discardableResult
    func ingest(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)

        if let match = Self.rxTxRegex.firstMatch(in: line, range: range),
           let rxPackets = Int(capture(match, 1, in: line) ?? ""),
           let rxBytes = Int(capture(match, 2, in: line) ?? ""),
           let txPackets = Int(capture(match, 3, in: line) ?? ""),
           let txBytes = Int(capture(match, 4, in: line) ?? "") {
            let sample = VpnStats(timestamp: Date(), rxPackets: rxPackets, rxBytes: rxBytes, txPackets: txPackets, txBytes: txBytes)
            samples.append(sample)
            if samples.count > maxSamples {
                samples.removeFirst(samples.count - maxSamples)
            }
            return true
        }

        if let match = Self.configuredRegex.firstMatch(in: line, range: range) {
            tunnelIP = capture(match, 1, in: line)
            tunnelStatus = capture(match, 2, in: line)?.trimmingCharacters(in: .whitespaces)
            return true
        }

        if let match = Self.expiryRegex.firstMatch(in: line, range: range) {
            sessionExpiry = capture(match, 1, in: line)?.trimmingCharacters(in: .whitespaces)
            return true
        }

        if let match = Self.ciphersuiteRegex.firstMatch(in: line, range: range) {
            sslCiphersuite = capture(match, 1, in: line)?.trimmingCharacters(in: .whitespaces)
            return true
        }

        return false
    }

    /// Resets for a new session (counters restart from zero with each new
    /// openconnect process).
    func clear() {
        samples.removeAll()
        tunnelIP = nil
        tunnelStatus = nil
        sessionExpiry = nil
        sslCiphersuite = nil
    }

    private func capture(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> String? {
        guard let range = Range(match.range(at: index), in: line) else { return nil }
        return String(line[range])
    }

    /// Derives an instantaneous throughput series (bytes/sec) from the
    /// cumulative RX/TX counters — the same raw samples the Python app logs
    /// verbatim every `STATS_INTERVAL` as `Current stats: VpnStats(...)`.
    /// Used to draw the menu's traffic graph instead of just logging text.
    func throughputSeries(maxPoints: Int = 30) -> [ThroughputPoint] {
        let recent = samples.suffix(maxPoints + 1)
        guard recent.count > 1 else { return [] }

        var points: [ThroughputPoint] = []
        var previous: VpnStats?
        for sample in recent {
            if let previous {
                let dt = sample.timestamp.timeIntervalSince(previous.timestamp)
                if dt > 0 {
                    let rxRate = max(0, Double(sample.rxBytes - previous.rxBytes) / dt)
                    let txRate = max(0, Double(sample.txBytes - previous.txBytes) / dt)
                    points.append(ThroughputPoint(time: sample.timestamp, rxBytesPerSecond: rxRate, txBytesPerSecond: txRate))
                }
            }
            previous = sample
        }
        return points
    }
}

/// One point of derived throughput (bytes/sec), used only for the graph —
/// not part of the raw stats stream itself.
struct ThroughputPoint: Identifiable {
    let id = UUID()
    let time: Date
    let rxBytesPerSecond: Double
    let txBytesPerSecond: Double
}
