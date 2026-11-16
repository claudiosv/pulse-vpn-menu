import Foundation

/// A UI-only stand-in for a live tunnel, for working on the menu header,
/// the traffic graph, and the Status tab without a VPN to connect to.
///
/// Enabled by launching with `--demo` (or `PULSE_VPN_MENU_DEMO=1`):
///
///     open -n "dist/Pulse VPN Menu.app" --args --demo
///
/// While enabled, `OpenConnectController` never talks to the tunnel
/// extension or the system's VPN configurations — so a demo instance is safe
/// to run next to a real one that has a tunnel up. Connect/Disconnect/Reconnect still work, but only
/// flip simulated state, and traffic counters come from `DemoTraffic`.
enum DemoMode {
    static let isEnabled: Bool = {
        if CommandLine.arguments.contains("--demo") { return true }
        return ProcessInfo.processInfo.environment["PULSE_VPN_MENU_DEMO"] == "1"
    }()

    /// What the simulated tunnel reports as its interface.
    static let tunnel = (name: "utun9", address: "10.64.12.34")

    /// How far back a session simulated at launch claims to have started,
    /// and the totals it starts from — so durations past an hour and
    /// three-digit MB counters are exercised too, not just "00:03".
    static let launchSessionAge: TimeInterval = 2 * 3600 + 7 * 60
    static let launchRxBytes = 255 * 1024 * 1024
    static let launchTxBytes = 120 * 1024 * 1024

    /// Samples prefilled at launch, enough to fill the menu's graph strip.
    static let launchSampleCount = 120
}

/// Generates plausible cumulative RX/TX counters: a slowly wandering idle
/// trickle with occasional multi-sample bursts (a page load, a download,
/// an upload), which is the shape that actually stresses the graph's
/// scaling — long quiet stretches next to short tall spikes.
struct DemoTraffic {
    private(set) var rxBytes: Int
    private(set) var txBytes: Int
    private(set) var rxPackets = 0
    private(set) var txPackets = 0

    private var phase = Double.random(in: 0..<100)
    private var downloadBurst = Burst()
    private var uploadBurst = Burst()

    private struct Burst {
        var remaining = 0
        var rate = 0.0

        /// Bytes/sec this burst contributes for the next sample, starting a
        /// new burst now and then when none is in progress.
        mutating func next(chance: Double, rates: ClosedRange<Double>) -> Double {
            if remaining == 0, Double.random(in: 0..<1) < chance {
                remaining = Int.random(in: 2...9)
                rate = Double.random(in: rates)
            }
            guard remaining > 0 else { return 0 }
            remaining -= 1
            return rate * Double.random(in: 0.6...1.0)
        }
    }

    init(rxBytes: Int = 0, txBytes: Int = 0) {
        self.rxBytes = rxBytes
        self.txBytes = txBytes
    }

    /// Advances the counters by `interval` seconds of simulated traffic.
    mutating func advance(by interval: TimeInterval) {
        phase += 1
        let idle = 30_000 * (1 + 0.6 * sin(phase / 7)) * Double.random(in: 0.5...1.5)
        let rxRate = idle + downloadBurst.next(chance: 0.07, rates: 400_000...5_000_000)
        let txRate = idle * 0.3 + rxRate * 0.04 + uploadBurst.next(chance: 0.04, rates: 200_000...2_000_000)

        let rx = Int(rxRate * interval)
        let tx = Int(txRate * interval)
        rxBytes += rx
        txBytes += tx
        rxPackets += max(1, rx / 1200)
        txPackets += max(1, tx / 1200)
    }

    func sample(at time: Date) -> VpnStats {
        VpnStats(timestamp: time, rxPackets: rxPackets, rxBytes: rxBytes, txPackets: txPackets, txBytes: txBytes)
    }
}
