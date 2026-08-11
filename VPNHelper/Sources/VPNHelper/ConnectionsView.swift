import SwiftUI

/// Connections tab: one glass card per connection with a direct Connect
/// button, plus Edit / Delete, and an Add Connection footer.
struct ConnectionsView: View {
    @EnvironmentObject var store: VPNStore
    let onEdit: (VPNConnection) -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    if store.connections.isEmpty {
                        Text("No connections yet. Add one to get started.")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 50)
                    } else {
                        ForEach(store.connections) { c in
                            row(for: c)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }

            Divider().opacity(0.5)
            HStack {
                Button(action: onAdd) {
                    Label("Add Connection", systemImage: "plus")
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Color.primary.opacity(0.02))
        }
    }

    private func isLive(_ c: VPNConnection) -> Bool { store.isConnected && c.isDefault }

    private func row(for c: VPNConnection) -> some View {
        HStack {
            Circle()
                .fill(isLive(c) ? Color.green : Color.primary.opacity(0.25))
                .frame(width: 10, height: 10)
                .padding(.trailing, 3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(c.name).font(.system(size: 15, weight: .semibold))
                    if c.isDefault {
                        Text("DEFAULT")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                }
                Text(c.url).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()

            Button(isLive(c) ? "Disconnect" : "Connect") {
                isLive(c) ? store.disconnect() : store.connect(c)
            }
            .buttonStyle(.borderedProminent)
            .tint(isLive(c) ? Color.gray : Color.accentColor)
            .controlSize(.small)

            Button("Edit") { onEdit(c) }
                .buttonStyle(.bordered).controlSize(.small)
            Button("Delete") { store.delete(c) }
                .buttonStyle(.bordered).controlSize(.small).tint(.red)
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        .background(RoundedRectangle(cornerRadius: 14).fill(.thinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06)))
    }
}
