import Foundation

/// Buffers a raw byte stream (openconnect's stdout or stderr) into
/// complete lines and writes each one to the destination log file with a
/// human-readable timestamp prefixed, matching the format `LogStore` uses
/// for the app's own diagnostic log (`app.log`) — openconnect itself never
/// timestamps its own output, so without this the two logs looked
/// inconsistent.
///
/// Not thread-safe on its own: callers must serialize every `consume(_:)`/
/// `flush()` call for a given destination file onto one queue (a stdout
/// instance and a stderr instance sharing the same `CappedLogFile` still
/// need their writes serialized against each other, even though each keeps
/// its own line buffer). `@unchecked Sendable` because that serialization
/// is enforced externally (both `HelperService` call sites only ever touch
/// an instance via the same dedicated `DispatchQueue`), not by this type
/// itself.
final class TimestampingLogWriter: @unchecked Sendable {
    private let logFile: CappedLogFile
    private var buffer = Data()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init(logFile: CappedLogFile) {
        self.logFile = logFile
    }

    /// Pass `Data()` (or call `flush()` directly) once the source stream
    /// reaches EOF, so a final line with no trailing newline isn't lost.
    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            writeLine(buffer[buffer.startIndex..<newlineIndex])
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        writeLine(buffer[buffer.startIndex...])
        buffer.removeAll()
    }

    private func writeLine(_ lineData: Data.SubSequence) {
        let line = String(decoding: lineData, as: UTF8.self)
        let timestamp = Self.timestampFormatter.string(from: Date())
        guard let data = "[\(timestamp)] \(line)\n".data(using: .utf8) else { return }
        logFile.write(data)
    }
}
