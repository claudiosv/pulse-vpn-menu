import Foundation

/// A single VPN endpoint the user can connect to. No real networking —
/// the fields mirror what an openconnect front-end would store.
struct VPNConnection: Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var vpncScript: String = ""
    var postConnect: String = ""
    var noDefaultRoute: Bool = false
    var verboseLogging: Bool = false
    var isDefault: Bool = false
}

/// App-wide preferences shown on the General tab.
struct GeneralSettings: Equatable {
    var pollInterval: Int = 5
    var disconnectOnQuit: Bool = false
    var hideRepeatedStats: Bool = true
}

/// One line in the activity log.
struct LogLine: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String

    var formatted: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return "\(f.string(from: timestamp))  \(message)"
    }
}

enum Tab: String, CaseIterable, Identifiable {
    case status = "Status"
    case connections = "Connections"
    case general = "General"
    var id: String { rawValue }
}
