import Foundation
import PulseVPNHelperProtocol

/// One stats sample. Byte/packet counters are cumulative for the session.
/// Mirrors Python's `stats.py`'s `VpnStats`.
struct VpnStats: Equatable {
    var timestamp: Date
    var rxPackets: Int
    var rxBytes: Int
    var txPackets: Int
    var txBytes: Int
}

/// Rolling history of the helper's traffic-counter samples, mirroring
/// `stats.py`'s `StatsHistory`. Not actor/lock-guarded like the Python
/// version since it's only ever touched on the main actor here (see
/// `OpenConnectController`).
@MainActor
final class StatsHistory: ObservableObject {
    @Published private(set) var samples: [VpnStats] = []

    private let maxSamples = 4096

    var current: VpnStats? { samples.last }

    /// Records the counters from a `SessionSnapshot`, stamped with when the
    /// helper sampled them (not when we happened to read them).
    func append(_ snapshot: SessionSnapshot) {
        samples.append(VpnStats(
            timestamp: snapshot.sampledAt,
            rxPackets: Int(clamping: snapshot.rxPackets),
            rxBytes: Int(clamping: snapshot.rxBytes),
            txPackets: Int(clamping: snapshot.txPackets),
            txBytes: Int(clamping: snapshot.txBytes)
        ))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    /// Resets for a new session (counters restart from zero with each new
    /// connection).
    func clear() {
        samples.removeAll()
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
