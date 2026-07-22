import Foundation

/// Loads/saves the list of `ConnectionProfile`s as JSON at
/// ~/Library/Application Support/Pulse VPN Menu/connections.json.
@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []
    @Published var defaultConnectionID: UUID?

    private struct Document: Codable {
        var profiles: [ConnectionProfile]
        var defaultConnectionID: UUID?
    }

    init() {
        load()
    }

    var defaultProfile: ConnectionProfile? {
        if let id = defaultConnectionID, let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        return profiles.first
    }

    func profile(id: UUID) -> ConnectionProfile? {
        profiles.first { $0.id == id }
    }

    func add(_ profile: ConnectionProfile) {
        profiles.append(profile)
        if defaultConnectionID == nil {
            defaultConnectionID = profile.id
        }
        save()
    }

    func update(_ profile: ConnectionProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
    }

    func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
        if defaultConnectionID == id {
            defaultConnectionID = profiles.first?.id
        }
        save()
    }

    func setDefault(id: UUID) {
        defaultConnectionID = id
        save()
    }

    /// Persists a DSID cookie captured for a profile (or clears it after a
    /// rejected-cookie exit) without needing the whole UI to re-render.
    func updateDSID(profileID: UUID, dsid: String?) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].lastDSID = dsid
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.connectionsFile) else { return }
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else { return }
        profiles = document.profiles
        defaultConnectionID = document.defaultConnectionID
    }

    private func save() {
        let document = Document(profiles: profiles, defaultConnectionID: defaultConnectionID)
        guard let data = try? JSONEncoder.pretty.encode(document) else { return }
        try? data.write(to: AppPaths.connectionsFile, options: .atomic)
    }
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
