import SwiftUI

/// General tab: app-wide preferences, each in its own glass card with an
/// explanatory footnote (mirrors the openconnect front-end options).
struct GeneralView: View {
    @EnvironmentObject var store: VPNStore

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                card {
                    HStack {
                        Text("Poll for stats every \(store.general.pollInterval)s")
                            .font(.system(size: 13.5))
                        Spacer()
                        Stepper("", value: $store.general.pollInterval, in: 1...60)
                            .labelsHidden()
                    }
                    footnote("How often the app asks openconnect (via SIGUSR1) for updated traffic stats while connected.")
                }

                card {
                    Toggle(isOn: $store.general.disconnectOnQuit) {
                        Text("Disconnect VPN when quitting the app").font(.system(size: 13.5))
                    }
                    .toggleStyle(.switch)
                    footnote("Off by default: quitting the menu bar app leaves an active tunnel running.")
                }

                card {
                    Toggle(isOn: $store.general.hideRepeatedStats) {
                        Text("Hide repeated stats lines in the log").font(.system(size: 13.5))
                    }
                    .toggleStyle(.switch)
                    footnote("Every stats poll re-prints the same \"Configured as…\", \"Session authentication will expire…\", \"RX/TX…\" and \"SSL ciphersuite…\" lines. When on, only the first occurrence per connection is shown; the traffic graph still updates from every poll either way.")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
        }
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.thinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06)))
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
