import SwiftUI

/// Connections tab: one card per saved `ConnectionProfile` with a direct
/// Connect/Disconnect button, plus Set Default / Edit / Delete and an Add
/// Connection footer. Replaces the `List`-based connections tab of the old
/// Settings window — connecting used to be possible only from the menu bar.
struct ConnectionsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var controller: OpenConnectController
    @EnvironmentObject private var connectionStore: ConnectionStore

    /// Drives `.sheet(item:)` directly: setting this to a (possibly brand
    /// new, blank) profile presents the editor with that exact identity,
    /// so `ConnectionEditView`'s `@State` always seeds fresh instead of
    /// potentially reusing stale state from a previous presentation.
    @State private var editingProfile: ConnectionProfile?
    @State private var profilePendingDeletion: ConnectionProfile?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    if connectionStore.profiles.isEmpty {
                        Text("No connections yet. Add one to get started.")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 50)
                    } else {
                        ForEach(connectionStore.profiles) { profile in
                            row(for: profile)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }

            Divider().opacity(0.5)

            HStack {
                Button {
                    editingProfile = ConnectionProfile(name: "", vpnURL: "https://")
                } label: {
                    Label("Add Connection", systemImage: "plus")
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.02))
        }
        .sheet(item: $editingProfile) { profile in
            ConnectionEditView(profile: profile) { saved in
                if connectionStore.profiles.contains(where: { $0.id == saved.id }) {
                    connectionStore.update(saved)
                } else {
                    connectionStore.add(saved)
                }
            }
        }
        .confirmationDialog(
            "Delete “\(profilePendingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { profilePendingDeletion != nil },
                set: { if !$0 { profilePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let profile = profilePendingDeletion {
                    connectionStore.delete(id: profile.id)
                }
                profilePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { profilePendingDeletion = nil }
        } message: {
            Text("This removes the saved connection and its cached login cookie.")
        }
    }

    /// Whether *this* profile is the one the live tunnel belongs to — not
    /// merely the default one, which is what the demo approximated.
    private func isLive(_ profile: ConnectionProfile) -> Bool {
        appState.isConnected && controller.connectedProfileID == profile.id
    }

    private func row(for profile: ConnectionProfile) -> some View {
        GlassCard(verticalPadding: 15) {
            HStack {
                Circle()
                    .fill(isLive(profile) ? Color.green : Color.primary.opacity(0.25))
                    .frame(width: 10, height: 10)
                    .padding(.trailing, 3)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(profile.name.isEmpty ? "Untitled" : profile.name)
                            .font(.system(size: 15, weight: .semibold))
                        if profile.id == connectionStore.defaultConnectionID {
                            Text("DEFAULT")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tint)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }
                    }
                    Text(profile.vpnURL)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 12)

                Button(isLive(profile) ? "Disconnect" : "Connect") {
                    if isLive(profile) {
                        appState.disconnect()
                    } else {
                        appState.connect(profile: profile)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(isLive(profile) ? Color.gray : Color.accentColor)
                .controlSize(.small)
                // Connecting while another tunnel is already up would leave
                // the first one orphaned, so only the live row can act.
                .disabled(controller.isBusy || (appState.isConnected && !isLive(profile)))

                if profile.id != connectionStore.defaultConnectionID {
                    Button("Set Default") { connectionStore.setDefault(id: profile.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                Button("Edit") { editingProfile = profile }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Delete") { profilePendingDeletion = profile }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
            }
        }
    }
}
