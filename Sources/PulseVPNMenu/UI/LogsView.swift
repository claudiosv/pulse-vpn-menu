import SwiftUI

/// Scrolling live view of openconnect's output. Bound directly to
/// `LogStore`, which seeds its history from disk on launch and keeps
/// tailing the log file, so this shows everything "since this
/// connection/app started" — not just what arrived while the window
/// happened to be open.
struct LogsView: View {
    @EnvironmentObject private var logStore: LogStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(logStore.lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: logStore.lines.count) { _, _ in
                guard let lastIndex = logStore.lines.indices.last else { return }
                withAnimation {
                    proxy.scrollTo(lastIndex, anchor: .bottom)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
