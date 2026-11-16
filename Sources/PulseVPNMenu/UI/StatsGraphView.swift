import Charts
import SwiftUI

/// Where a `StatsGraphView` is being drawn, which decides sizing, labels,
/// and axis detail.
enum StatsGraphStyle {
    /// Embedded in the menu bar dropdown's header: a short monochrome
    /// strip of mirrored bars (download above the midline, upload below),
    /// with no axes or labels — the header prints the totals itself.
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
/// counters the extension reports on each stats poll.
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

    var body: some View {
        switch style {
        case .menu:
            MenuTrafficBars(points: stats.throughputSeries(maxPoints: MenuTrafficBars.maxBars))
        case .card:
            card
        }
    }

    @ViewBuilder
    private var card: some View {
        let points = stats.throughputSeries(maxPoints: 60)

        if points.isEmpty {
            Text("No traffic stats yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            chart(points: points)
        }
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
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(Traffic.rate(bytes)).font(.system(size: 9))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 0)) { _ in }
        }
    }
}

/// The menu header's traffic strip: one thin bar per stats sample, newest
/// on the right, mirrored around the midline — download grows upward,
/// upload downward (drawn fainter, like a reflection). Slots with no
/// sample yet, and samples with no traffic, still draw a 1pt dot each way
/// so the strip reads as a continuous baseline rather than a blank gap.
///
/// Heights use a square-root scale against the busiest sample in view:
/// VPN traffic is bursty, and on a linear scale one large transfer would
/// flatten everything else in a strip this short down to the baseline.
private struct MenuTrafficBars: View {
    let points: [ThroughputPoint]

    /// More than fit at the header's width; the canvas keeps the newest
    /// ones that do.
    static let maxBars = 120

    private static let barWidth: CGFloat = 2
    private static let pitch: CGFloat = 3
    private static let height: CGFloat = 14

    var body: some View {
        Canvas { context, size in
            let slots = max(0, Int((size.width + Self.pitch - Self.barWidth) / Self.pitch))
            let recent = Array(points.suffix(slots))
            let peak = recent.map { max($0.rxBytesPerSecond, $0.txBytesPerSecond) }.max() ?? 0
            let mid = size.height / 2
            let offset = slots - recent.count

            var downloads = Path()
            var uploads = Path()
            for slot in 0..<slots {
                var up: CGFloat = 1
                var down: CGFloat = 1
                if slot >= offset, peak > 0 {
                    let point = recent[slot - offset]
                    up = max(1, mid * (point.rxBytesPerSecond / peak).squareRoot())
                    down = max(1, mid * (point.txBytesPerSecond / peak).squareRoot())
                }
                let x = CGFloat(slot) * Self.pitch
                downloads.addRect(CGRect(x: x, y: mid - up, width: Self.barWidth, height: up))
                uploads.addRect(CGRect(x: x, y: mid, width: Self.barWidth, height: down))
            }
            context.fill(downloads, with: .color(.primary.opacity(0.5)))
            context.fill(uploads, with: .color(.primary.opacity(0.28)))
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
    }
}
