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
                        Text("How often the app asks the VPN session for updated traffic stats while connected.")
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
                        Toggle(isOn: $appSettings.keepBrowserSession) {
                            Text("Keep the browser login between connections")
                                .font(.system(size: 13.5))
                        }
                        .toggleStyle(.switch)
                        Text("Keeps the sign-in cookies that expire when the browser closes (many single sign-on pages use them), so they don't ask again. Off by default: the login window then reopens the last tabs and takes a moment longer to close.")
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
                        Text("Posts a notification when the VPN session ends without you clicking Disconnect — it expired, it gave up reconnecting, or the VPN extension crashed.")
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
                        Text("Posts a notification when the VPN link drops and the session starts retrying on its own (for up to 30s), and another when it reconnects.")
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
