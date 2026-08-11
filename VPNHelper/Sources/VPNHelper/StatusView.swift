import SwiftUI

/// Primary screen: big power button, live status, connection switcher,
/// traffic stats + graph, and a collapsible activity log.
struct StatusView: View {
    @EnvironmentObject var store: VPNStore
    @State private var showPicker = false
    @State private var showLog = false
    @State private var pulse = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                powerButton
                    .padding(.top, 28)

                Text(store.statusText)
                    .font(.system(size: 20, weight: .bold))
                    .padding(.top, 20)
                Text(store.isConnected ? "Tunnel active · click to disconnect"
                                       : "Click the button to connect")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)

                connectionSwitcher
                    .padding(.top, 18)

                if store.isConnected {
                    statsCard.padding(.top, 18)
                }

                activityLog.padding(.top, 14)
            }
            .frame(maxWidth: 340)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    // MARK: Power button

    private var powerButton: some View {
        ZStack {
            if store.isConnected {
                Circle()
                    .fill(Color.green.opacity(0.28))
                    .frame(width: 160, height: 160)
                    .scaleEffect(pulse ? 1.35 : 1)
                    .opacity(pulse ? 0.15 : 0.5)
                    .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: pulse)
            }
            Button(action: store.toggleConnect) {
                Image(systemName: "power")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(store.isConnected ? Color.green : Color.secondary)
                    .frame(width: 148, height: 148)
                    .background {
                        Circle()
                            .fill(store.isConnected ? Color.green.opacity(0.12) : Color.primary.opacity(0.04))
                            .overlay(Circle().stroke(store.isConnected ? Color.green.opacity(0.5)
                                                                       : Color.primary.opacity(0.1), lineWidth: 1.5))
                    }
                    .shadow(color: store.isConnected ? Color.green.opacity(0.35) : .clear, radius: 22)
            }
            .buttonStyle(.plain)
        }
        .onAppear { pulse = store.isConnected }
        .onChange(of: store.isConnected) { _, on in pulse = on }
    }

    // MARK: Connection switcher

    private var connectionSwitcher: some View {
        Button {
            showPicker.toggle()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.defaultConnection?.name ?? "—")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(store.defaultConnection?.url ?? "")
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
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.connections) { c in
                    Button {
                        store.setDefault(c)
                        showPicker = false
                    } label: {
                        HStack {
                            Text(c.name)
                            Spacer()
                            if c.isDefault { Text("Selected").foregroundStyle(.tint) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .frame(width: 240, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Divider()
                Button("Manage connections…") {
                    showPicker = false
                    store.selectedTab = .connections
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
            .padding(5)
        }
    }

    // MARK: Stats + graph

    private var statsCard: some View {
        VStack(spacing: 14) {
            HStack {
                stat("Duration", store.durationString, .primary)
                Spacer()
                stat("↓ Down", store.formatSize(store.downTotalKB), .green)
                Spacer()
                stat("↑ Up", store.formatSize(store.upTotalKB), .blue)
            }
            TrafficGraph(down: store.downSamples, up: store.upSamples)
                .frame(height: 56)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }

    // MARK: Activity log

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
                    Text(showLog ? "▲" : "▾").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showLog {
                VStack(alignment: .leading, spacing: 3) {
                    if store.log.isEmpty {
                        Text("No activity yet — hit connect to start a tunnel.")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(store.log.reversed()) { line in
                            Text(line.formatted)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }
        }
    }
}

/// Simple filled down-line + up-line traffic sparkline.
struct TrafficGraph: View {
    let down: [Double]
    let up: [Double]
    private let maxV: Double = 120

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                area(down, in: CGSize(width: w, height: h)).fill(Color.green.opacity(0.14))
                line(down, in: CGSize(width: w, height: h)).stroke(Color.green, lineWidth: 1.5)
                line(up, in: CGSize(width: w, height: h)).stroke(Color.blue, lineWidth: 1.5)
            }
        }
    }

    private func points(_ arr: [Double], in size: CGSize) -> [CGPoint] {
        let n = 48
        let padded = arr.count < n ? Array(repeating: 0, count: n - arr.count) + arr : Array(arr.suffix(n))
        return padded.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) / CGFloat(n - 1) * size.width,
                    y: size.height - min(1, v / maxV) * size.height)
        }
    }

    private func line(_ arr: [Double], in size: CGSize) -> Path {
        Path { p in
            let pts = points(arr, in: size)
            guard let first = pts.first else { return }
            p.move(to: first)
            pts.dropFirst().forEach { p.addLine(to: $0) }
        }
    }

    private func area(_ arr: [Double], in size: CGSize) -> Path {
        Path { p in
            let pts = points(arr, in: size)
            guard let first = pts.first else { return }
            p.move(to: CGPoint(x: 0, y: size.height))
            p.addLine(to: first)
            pts.dropFirst().forEach { p.addLine(to: $0) }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
        }
    }
}
