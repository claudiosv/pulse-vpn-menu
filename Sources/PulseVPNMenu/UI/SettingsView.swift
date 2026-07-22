import SwiftUI

/// Lists saved VPN connection profiles with add/edit/delete/set-default,
/// replacing the Python app's single-profile `config.toml` editing (there
/// was no UI for it at all — the file had to be hand-edited).
struct SettingsView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    /// Drives `.sheet(item:)` directly: setting this to a (possibly brand
    /// new, blank) profile presents the editor with that exact identity,
    /// so `ConnectionEditView`'s `@State` always seeds fresh instead of
    /// potentially reusing stale state from a previous presentation.
    @State private var editingProfile: ConnectionProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if connectionStore.profiles.isEmpty {
                ContentUnavailableView(
                    "No Connections",
                    systemImage: "network.slash",
                    description: Text("Add a VPN connection to get started.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(connectionStore.profiles) { profile in
                        row(for: profile)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button {
                    editingProfile = ConnectionProfile(name: "", vpnURL: "https://")
                } label: {
                    Label("Add Connection", systemImage: "plus")
                }
                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 360)
        .sheet(item: $editingProfile) { profile in
            ConnectionEditView(profile: profile) { saved in
                if connectionStore.profiles.contains(where: { $0.id == saved.id }) {
                    connectionStore.update(saved)
                } else {
                    connectionStore.add(saved)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for profile: ConnectionProfile) -> some View {
        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 4) {
                    Text(profile.name).bold()
                    if profile.id == connectionStore.defaultConnectionID {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(profile.vpnURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit") {
                editingProfile = profile
            }
            Button("Set Default") {
                connectionStore.setDefault(id: profile.id)
            }
            .disabled(profile.id == connectionStore.defaultConnectionID)
            Button(role: .destructive) {
                connectionStore.delete(id: profile.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}
