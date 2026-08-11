import SwiftUI

/// Lean menu bar dropdown: status, connect/disconnect, open window, quit.
struct MenuBarView: View {
    @EnvironmentObject var store: VPNStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(store.isConnected ? Color.green : Color.secondary)
                        .frame(width: 9, height: 9)
                    Text(store.statusText).font(.system(size: 14, weight: .bold))
                }
                Text(store.defaultConnection?.url ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 17)

                Button(action: store.toggleConnect) {
                    Text(store.isConnected ? "Disconnect" : "Connect")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .tint(store.isConnected ? Color.gray : Color.accentColor)
                .padding(.top, 12)
            }
            .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 8)

            Divider()
            menuButton("Open VPN Helper…") { openWindow(id: "main") }
            menuButton("Quit VPN Helper") { NSApplication.shared.terminate(nil) }
                .padding(.bottom, 6)
        }
        .frame(width: 284)
    }

    private func menuButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
