import SwiftUI
import Combine

/// Central observable state. All "connection" behaviour is simulated:
/// a timer fakes traffic stats and appends log lines, so the UI is fully
/// functional without touching any real VPN.
@MainActor
final class VPNStore: ObservableObject {
    @Published var connections: [VPNConnection]
    @Published var general = GeneralSettings()

    @Published var isConnected = false
    @Published var elapsedSeconds = 0
    @Published var downSamples: [Double] = []
    @Published var upSamples: [Double] = []
    @Published var downTotalKB: Double = 0
    @Published var upTotalKB: Double = 0
    @Published var log: [LogLine] = []

    @Published var selectedTab: Tab = .status

    private var timer: AnyCancellable?

    init() {
        connections = [
            VPNConnection(
                name: "coe",
                url: "https://vpn.engineering.ucdavis.edu",
                vpncScript: "vpn-slice 169.237.0.0/16 vpn.engineering.ucdavis.edu",
                noDefaultRoute: true,
                verboseLogging: true,
                isDefault: true
            )
        ]
        startTicking()
    }

    // MARK: Derived

    var defaultConnection: VPNConnection? {
        connections.first(where: { $0.isDefault }) ?? connections.first
    }

    var statusText: String {
        guard isConnected, let c = defaultConnection else { return "Not Connected" }
        return "Connected to \(c.name)"
    }

    var durationString: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    func formatSize(_ kb: Double) -> String {
        kb >= 1024 ? String(format: "%.1f MB", kb / 1024) : "\(Int(kb)) KB"
    }

    // MARK: Connection lifecycle (simulated)

    func toggleConnect() {
        if isConnected { disconnect() }
        else { connect(defaultConnection) }
    }

    func connect(_ connection: VPNConnection?) {
        guard let c = connection else { return }
        setDefault(c)
        isConnected = true
        elapsedSeconds = 0
        downSamples = []; upSamples = []
        downTotalKB = 0; upTotalKB = 0
        appendLog("Connecting to \(c.name)…")
        appendLog("Tunnel established (\(c.url))")
    }

    func disconnect() {
        isConnected = false
        appendLog("Disconnected")
    }

    // MARK: Connection management

    func setDefault(_ connection: VPNConnection) {
        for i in connections.indices {
            connections[i].isDefault = connections[i].id == connection.id
        }
    }

    func upsert(_ connection: VPNConnection) {
        if let idx = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[idx] = connection
        } else {
            var new = connection
            if connections.isEmpty { new.isDefault = true }
            connections.append(new)
        }
    }

    func delete(_ connection: VPNConnection) {
        connections.removeAll { $0.id == connection.id }
        if !connections.isEmpty && !connections.contains(where: { $0.isDefault }) {
            connections[0].isDefault = true
        }
    }

    // MARK: Logging

    func appendLog(_ message: String) {
        log.append(LogLine(timestamp: Date(), message: message))
    }

    // MARK: Fake traffic ticker

    private func startTicking() {
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard isConnected else { return }
        let t = Double(elapsedSeconds)
        let down = 40 + sin(t / 3) * 22 + Double.random(in: 0..<24)
        let up = 12 + sin(t / 4 + 1) * 7 + Double.random(in: 0..<8)
        elapsedSeconds += 1
        downSamples = Array((downSamples + [down]).suffix(48))
        upSamples = Array((upSamples + [up]).suffix(48))
        downTotalKB += down
        upTotalKB += up
    }
}
