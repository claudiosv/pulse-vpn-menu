import Foundation

/// Wraps `current.log`'s destination `FileHandle`, keeping the file
/// roughly bounded at `capBytes` by trimming the oldest content once it
/// grows past the limit — a long-running, idle-but-still-polled connection
/// otherwise re-prints the same stats block forever with nothing to stop
/// the file from growing without bound. Trimming keeps the most recent
/// half of the cap (at a line boundary, so no line is left cut in half),
/// truncates the file, and rewrites just that tail.
///
/// Not thread-safe on its own: every `write(_:)` call must be serialized
/// externally (both `TimestampingLogWriter` instances share one
/// `CappedLogFile`, via the same dispatch queue). `@unchecked Sendable`
/// for the same reason as `TimestampingLogWriter`.
final class CappedLogFile: @unchecked Sendable {
    private let path: String
    private var handle: FileHandle
    private var currentSize: UInt64
    private let capBytes: UInt64

    init?(path: String, capBytes: UInt64 = 1_048_576) {
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        self.path = path
        self.handle = handle
        self.capBytes = capBytes
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        self.currentSize = (attributes?[.size] as? UInt64) ?? 0
        handle.seekToEndOfFile()
    }

    func write(_ data: Data) {
        handle.write(data)
        currentSize += UInt64(data.count)
        if currentSize > capBytes {
            trim()
        }
    }

    func close() {
        try? handle.close()
    }

    private func trim() {
        guard let fullData = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let keepBudget = Int(capBytes / 2)
        let keepFrom = fullData.count > keepBudget ? fullData.count - keepBudget : 0
        var trimmed = fullData.suffix(from: keepFrom)
        // Drop any partial line at the very start of the kept region so the
        // first line in the trimmed file is always whole.
        if keepFrom > 0, let newlineIndex = trimmed.firstIndex(of: UInt8(ascii: "\n")) {
            trimmed = trimmed.suffix(from: trimmed.index(after: newlineIndex))
        }

        let newData = Data(trimmed)
        handle.truncateFile(atOffset: 0)
        handle.write(newData)
        currentSize = UInt64(newData.count)
    }
}
