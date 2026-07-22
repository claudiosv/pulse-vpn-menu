import Charts
import SwiftUI

/// A live traffic graph, built on the same `StatsHistory` data the Python
/// app only ever logged as text
/// (`logger.info("Current stats: %s", str(self.stats.current))`). Plots
/// download/upload throughput derived from the raw cumulative RX/TX
/// counters openconnect reports on each SIGUSR1 poke.
///
/// `compact` controls sizing: `true` embeds it directly in the menu bar
/// dropdown (small fonts, tight padding, fixed size); `false` is meant for
/// a full-size standalone window.
///
/// This used to be forced into `.menu`-style `MenuBarExtra` content,
/// rendered offscreen into a bitmap (since native `NSMenu` only knows how
/// to place `Text`/`Button`/`Divider` as real menu items — a live `Chart`
/// placed directly in that content gets silently dropped). That hit a hard
/// wall: NSMenu treats *any* image-based menu-item content as a small icon
/// glyph and force-shrinks it, ignoring the SwiftUI-level frame/size
/// entirely — so the graph was stuck tiny no matter how large the source
/// bitmap was rendered. Switching `MenuBarExtra` to `.menuBarExtraStyle(.window)`
/// (a real SwiftUI popover, not NSMenu) removes that constraint entirely,
/// so this can now be a genuine live `Chart` embedded right in the dropdown.
struct StatsGraphView: View {
    @ObservedObject var stats: StatsHistory
    var compact: Bool = false

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter
    }()

    var body: some View {
        let points = stats.throughputSeries(maxPoints: compact ? 40 : 120)

        VStack(alignment: .leading, spacing: compact ? 8 : 16) {
            if let latest = points.last {
                HStack(spacing: compact ? 16 : 28) {
                    label(systemImage: "arrow.down.circle.fill", value: latest.rxBytesPerSecond, color: .blue)
                    label(systemImage: "arrow.up.circle.fill", value: latest.txBytesPerSecond, color: .orange)
                }
            }

            if points.isEmpty {
                if compact {
                    Text("No traffic stats yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                } else {
                    ContentUnavailableView(
                        "No Traffic Yet",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Stats appear once connected and openconnect starts reporting RX/TX.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                chart(points: points)
            }
        }
        .padding(compact ? 12 : 20)
        .frame(
            minWidth: compact ? 280 : 520,
            idealWidth: compact ? 300 : 600,
            minHeight: compact ? 140 : 360,
            idealHeight: compact ? 150 : 400
        )
    }

    @ViewBuilder
    private func chart(points: [ThroughputPoint]) -> some View {
        Chart(points) { point in
            LineMark(
                x: .value("Time", point.time),
                y: .value("Bytes/sec", point.rxBytesPerSecond)
            )
            .foregroundStyle(by: .value("Direction", "Download"))
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: compact ? 1.5 : 2))

            LineMark(
                x: .value("Time", point.time),
                y: .value("Bytes/sec", point.txBytesPerSecond)
            )
            .foregroundStyle(by: .value("Direction", "Upload"))
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: compact ? 1.5 : 2))
        }
        .chartForegroundStyleScale(["Download": Color.blue, "Upload": Color.orange])
        .chartLegend(compact ? .hidden : .visible)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: compact ? 3 : 6)) { value in
                AxisGridLine()
                if !compact {
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) {
                            Text(Self.byteFormatter.string(fromByteCount: Int64(bytes)) + "/s")
                        }
                    }
                }
            }
        }
        .chartXAxis {
            if compact {
                AxisMarks(values: .automatic(desiredCount: 0)) { _ in }
            } else {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute().second())
                }
            }
        }
    }

    private func label(systemImage: String, value: Double, color: Color) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .font(compact ? .callout : .title3)
            Text(Self.byteFormatter.string(fromByteCount: Int64(value)) + "/s")
                .font(compact ? .callout.weight(.medium) : .title3.weight(.medium))
        }
    }
}
