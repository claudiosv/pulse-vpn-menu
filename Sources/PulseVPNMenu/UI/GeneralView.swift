import SwiftUI

/// General tab: the app-wide preferences that used to be a grouped `Form`
/// in the Settings window, restyled as one card per setting with its
/// explanation inline instead of as a section footer.
struct GeneralView: View {
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Poll for stats every \(Int(appSettings.statsPollInterval))s")
                                .font(.system(size: 13.5))
                            Spacer()
                            Stepper(
                                "",
                                value: $appSettings.statsPollInterval,
                                in: AppSettings.statsPollIntervalRange,
                                step: 1
                            )
                            .labelsHidden()
                        }
                        Text("How often the app asks openconnect (via SIGUSR1) for updated traffic stats while connected.")
                            .cardFootnote()
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $appSettings.disconnectOnQuit) {
                            Text("Disconnect VPN when quitting the app")
                                .font(.system(size: 13.5))
                        }
                        .toggleStyle(.switch)
                        Text("Off by default: quitting the menu bar app leaves an active tunnel running.")
                            .cardFootnote()
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $appSettings.hideRepeatedStatsLines) {
                            Text("Hide repeated stats lines in the log")
                                .font(.system(size: 13.5))
                        }
                        .toggleStyle(.switch)
                        Text("Every stats poll re-prints the same \"Configured as…\", \"Session authentication will expire…\", \"RX/TX…\", and \"SSL ciphersuite…\" lines. When on, only the first occurrence per connection is shown; the traffic graph still updates from every poll either way.")
                            .cardFootnote()
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $appSettings.notifyOnUnexpectedDisconnect) {
                            Text("Notify when the VPN disconnects unexpectedly")
                                .font(.system(size: 13.5))
                        }
                        .toggleStyle(.switch)
                        Text("Posts a notification when openconnect exits without you clicking Disconnect — the session expired, it gave up reconnecting, or it crashed.")
                            .cardFootnote()
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $appSettings.notifyOnTransientDrops) {
                            Text("Also notify on transient drops")
                                .font(.system(size: 13.5))
                        }
                        .toggleStyle(.switch)
                        Text("Posts a notification when openconnect loses the link and starts retrying on its own (for up to 30s), and another when it reconnects.")
                            .cardFootnote()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .onChange(of: appSettings.notifyOnUnexpectedDisconnect) { _, isOn in
            if isOn { Notifier.shared.requestAuthorizationIfNeeded() }
        }
        .onChange(of: appSettings.notifyOnTransientDrops) { _, isOn in
            if isOn { Notifier.shared.requestAuthorizationIfNeeded() }
        }
    }
}
