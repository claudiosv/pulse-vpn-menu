import Charts
import SwiftUI

/// Where a `StatsGraphView` is being drawn, which decides sizing, labels,
/// and axis detail.
enum StatsGraphStyle {
    /// Embedded in the menu bar dropdown: small fonts, tight padding, a
    /// fixed size, and its own current-throughput readouts.
    case menu
    /// Embedded in the Status tab's stats card, which already shows
    /// duration and cumulative totals above it — so this draws the trend
    /// line only and takes whatever height the caller gives it.
    case card
}

/// A live traffic graph, built on the same `StatsHistory` data the Python
/// app only ever logged as text
/// (`logger.info("Current stats: %s", str(self.stats.current))`). Plots
/// download/upload throughput derived from the raw cumulative RX/TX
/// counters openconnect reports on each SIGUSR1 poke.
///
/// This used to be forced into `.menu`-style `MenuBarExtra` content,
/// rendered offscreen into a bitmap (since native `NSMenu` only knows how
/// to place `Text`/`Button`/`Divider` as real menu items — a live `Chart`
/// placed directly in that content gets silently dropped). That hit a hard
/// wall: NSMenu treats *any* image-based menu-item content as a small icon
/// glyph and force-shrinks it, ignoring the SwiftUI-level frame/size
/// entirely — so the graph was stuck tiny no matter how large the source
/// bitmap was rendered. The menu is now a real `NSMenu` with this view
/// hosted in a single `NSMenuItem.view` via `NSHostingView`, which removes
/// that constraint entirely (see `AppDelegate`).
struct StatsGraphView: View {
    @ObservedObject var stats: StatsHistory
    var style: StatsGraphStyle = .menu

    private var isMenu: Bool { style == .menu }

    var body: some View {
        let points = stats.throughputSeries(maxPoints: isMenu ? 40 : 60)

        VStack(alignment: .leading, spacing: 8) {
            if isMenu, let latest = points.last {
                HStack(spacing: 16) {
                    label(systemImage: "arrow.down.circle.fill", value: latest.rxBytesPerSecond, color: .blue)
                    label(systemImage: "arrow.up.circle.fill", value: latest.txBytesPerSecond, color: .orange)
                }
            }

            if points.isEmpty {
                Text("No traffic stats yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                chart(points: points)
            }
        }
        .padding(isMenu ? 12 : 0)
        .frame(
            minWidth: isMenu ? 280 : nil,
            idealWidth: isMenu ? 300 : nil,
            minHeight: isMenu ? 140 : nil,
            idealHeight: isMenu ? 150 : nil
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
            .lineStyle(StrokeStyle(lineWidth: 1.5))

            LineMark(
                x: .value("Time", point.time),
                y: .value("Bytes/sec", point.txBytesPerSecond)
            )
            .foregroundStyle(by: .value("Direction", "Upload"))
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartForegroundStyleScale(["Download": Color.blue, "Upload": Color.orange])
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                if !isMenu {
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) {
                            Text(Traffic.rate(bytes)).font(.system(size: 9))
                        }
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 0)) { _ in }
        }
    }

    private func label(systemImage: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .font(.callout)
            Text(Traffic.rate(value))
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
    }
}
