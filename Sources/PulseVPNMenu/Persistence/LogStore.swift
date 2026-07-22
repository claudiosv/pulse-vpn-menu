import Foundation

/// In-memory ring buffer of log lines, backed by a persistent file
/// (`Logs/current.log`) that is tailed live. History survives closing and
/// reopening the Logs window, and survives an app relaunch (seeded from the
/// file on init), not just the lifetime of the window.
@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var lines: [String] = []

    private let maxLines = 5000
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var readOffset: UInt64 = 0

    /// Invoked once per newly-appended line (including lines seeded from
    /// disk at startup), so other components (stats parsing) can observe
    /// the same stream without duplicating the tailing logic.
    var onLine: ((String) -> Void)?

    init() {
        seedFromDisk()
        startTailing()
    }

    deinit {
        source?.cancel()
        try? fileHandle?.close()
    }

    /// Called at the start of each new connection attempt so the Logs
    /// window reads as "since this connection started."
    func resetForNewConnection() {
        lines.removeAll()
        readOffset = 0
        stopTailing()
        startTailing()
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    func append(_ text: String) {
        appendLines(text: text)
        persistToAppLog(text)
    }

    /// Timestamps and appends to `AppPaths.appLogFile`, which is never
    /// truncated (unlike `current.log`) — see that path's doc comment.
    /// Only messages that go through `append(_:)` (the app's own
    /// diagnostics) are persisted here, not the tailed openconnect output
    /// ingested via `readNewData`, which would otherwise turn this into an
    /// unbounded copy of every RX/TX stats line ever logged.
    private func persistToAppLog(_ text: String) {
        let newLines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !newLines.isEmpty else { return }
        let timestamp = Self.timestampFormatter.string(from: Date())
        let block = newLines.map { "[\(timestamp)] \($0)\n" }.joined()
        guard let data = block.data(using: .utf8) else { return }

        let path = AppPaths.appLogFile.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644])
        }
        guard let handle = try? FileHandle(forWritingTo: AppPaths.appLogFile) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    }

    private func seedFromDisk() {
        guard let data = try? Data(contentsOf: AppPaths.currentLogFile) else { return }
        readOffset = UInt64(data.count)
        appendLines(text: String(decoding: data, as: UTF8.self))
    }

    private func startTailing() {
        let path = AppPaths.currentLogFile.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o666])
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        fileHandle = handle

        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            self?.readNewData()
        }
        src.setCancelHandler {
            try? handle.close()
        }
        src.resume()
        source = src
    }

    private func stopTailing() {
        source?.cancel()
        source = nil
        fileHandle = nil
    }

    private func readNewData() {
        guard let data = try? Data(contentsOf: AppPaths.currentLogFile) else { return }
        guard UInt64(data.count) > readOffset else { return }
        let newData = data.suffix(from: Int(readOffset))
        readOffset = UInt64(data.count)
        appendLines(text: String(decoding: newData, as: UTF8.self))
    }

    private func appendLines(text: String) {
        guard !text.isEmpty else { return }
        let newLines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !newLines.isEmpty else { return }
        lines.append(contentsOf: newLines)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        for line in newLines {
            onLine?(line)
        }
    }
}
