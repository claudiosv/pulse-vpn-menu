import SwiftUI

/// Primary screen: a big power button, live status, a connection switcher,
/// session stats + traffic graph, and a peek at recent log activity.
///
/// Everything here reflects real state — `AppState.isConnected` (polled
/// from the live openconnect pid), `OpenConnectController.isBusy`, the
/// `StatsHistory` samples parsed out of openconnect's SIGUSR1 dumps, and
/// `LogStore`'s tail. Nothing is simulated.
struct StatusView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var controller: OpenConnectController
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var logStore: LogStore

    @State private var showPicker = false
    @State private var showLog = false
    @State private var pulse = false

    private var isConnected: Bool { appState.isConnected }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                powerButton
                    .padding(.top, 28)

                Text(appState.statusTitle)
                    .font(.system(size: 20, weight: .bold))
                    .padding(.top, 20)
                Text(appState.statusDetail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)

                connectionSwitcher
                    .padding(.top, 18)

                if isConnected {
                    statsCard.padding(.top, 18)
                }

                activityLog.padding(.top, 14)
            }
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    // MARK: - Power button

    /// Green + pulsing when the tunnel is up, a spinner while connecting or
    /// disconnecting (the connect flow can take a while — it drives a real
    /// Chrome window for the DSID login), grey otherwise.
    private var powerButton: some View {
        ZStack {
            if isConnected {
                Circle()
                    .fill(Color.green.opacity(0.28))
                    .frame(width: 160, height: 160)
                    .scaleEffect(pulse ? 1.35 : 1)
                    .opacity(pulse ? 0.15 : 0.5)
                    .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: pulse)
            }

            Button(action: appState.toggleConnect) {
                Group {
                    if controller.isBusy {
                        ProgressView()
                            .controlSize(.large)
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 46, weight: .semibold))
                            .foregroundStyle(isConnected ? Color.green : Color.secondary)
                    }
                }
                .frame(width: 148, height: 148)
                .background {
                    Circle()
                        .fill(isConnected ? Color.green.opacity(0.12) : Color.primary.opacity(0.04))
                        .overlay(
                            Circle().stroke(
                                isConnected ? Color.green.opacity(0.5) : Color.primary.opacity(0.1),
                                lineWidth: 1.5
                            )
                        )
                }
                .shadow(color: isConnected ? Color.green.opacity(0.35) : .clear, radius: 22)
            }
            .buttonStyle(.plain)
            .disabled(controller.isBusy)
        }
        .onAppear { pulse = isConnected }
        .onChange(of: isConnected) { _, connected in pulse = connected }
    }

    // MARK: - Connection switcher

    /// Picks which profile the power button (and the menu bar's Connect
    /// item) will use — i.e. it edits `ConnectionStore.defaultConnectionID`,
    /// the same setting the old Settings window exposed as a "Set Default"
    /// button buried in a list row.
    private var connectionSwitcher: some View {
        Button {
            showPicker.toggle()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.activeProfile?.name ?? "No connections")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(appState.activeProfile?.vpnURL ?? "Add one on the Connections tab")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text("Switch \(showPicker ? "▲" : "▾")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(connectionStore.profiles) { profile in
                    Button {
                        connectionStore.setDefault(id: profile.id)
                        showPicker = false
                    } label: {
                        HStack {
                            Text(profile.name)
                            Spacer()
                            if profile.id == connectionStore.defaultConnectionID {
                                Text("Selected").foregroundStyle(.tint)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(width: 260, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if !connectionStore.profiles.isEmpty {
                    Divider()
                }

                Button("Manage connections…") {
                    showPicker = false
                    appState.selectedTab = .connections
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(width: 260, alignment: .leading)
                .contentShape(Rectangle())
            }
            .padding(5)
        }
    }

    // MARK: - Stats + graph

    /// Session duration, cumulative RX/TX, and the live throughput graph.
    /// `TimelineView` re-renders the duration once a second without needing
    /// its own timer or any extra published state — `connectedSince` comes
    /// straight off the persisted `RuntimeState`, so it survives an app
    /// relaunch that reattaches to a running tunnel.
    private var statsCard: some View {
        VStack(spacing: 14) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(alignment: .top) {
                    stat("Duration", durationText, .primary)
                    Spacer()
                    stat("↓ Down", Traffic.bytes(Double(controller.stats.current?.rxBytes ?? 0)), .blue)
                    Spacer()
                    stat("↑ Up", Traffic.bytes(Double(controller.stats.current?.txBytes ?? 0)), .orange)
                }
            }

            StatsGraphView(stats: controller.stats, style: .card)
                .frame(height: 84)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
    }

    private var durationText: String {
        guard let since = controller.connectedSince else { return "—" }
        return Traffic.duration(Date().timeIntervalSince(since))
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }

    // MARK: - Recent activity

    /// A short tail of the log, collapsed by default. The Logs tab remains
    /// the full, scrollable, selectable view — this is just enough to see
    /// what the connection is doing without leaving Status.
    private var activityLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showLog.toggle() }
            } label: {
                HStack {
                    Text("Recent activity")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(showLog ? "▲" : "▾")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showLog {
                VStack(alignment: .leading, spacing: 3) {
                    let recent = Array(logStore.lines.suffix(8))
                    if recent.isEmpty {
                        Text("No activity yet — hit connect to start a tunnel.")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(Array(recent.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }

                        Button("Open full log") { appState.selectedTab = .logs }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tint)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }
        }
    }
}
