import Foundation

/// The session's recent log lines, held in memory until the app collects
/// them. The provider is sandboxed and runs as root, so it cannot write the
/// user's log file itself; the app polls for lines newer than the last one
/// it has (`lines(after:)`) and writes them.
///
/// Text arrives in arbitrary pieces (libopenconnect's output may or may not
/// end in a newline); each completed line is timestamped when it completes,
/// in the same format the app uses for its own log.
public final class LogRing: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var lines: [String] = []
    /// Sequence number of the last line in `lines`; the first line ever is 1.
    private var lastSequence = 0
    private var partial = ""

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    public init(capacity: Int = 4000) {
        self.capacity = capacity
    }

    public func append(_ text: String) {
        lock.withLock {
            partial += text
            while let newline = partial.firstIndex(of: "\n") {
                store(String(partial[..<newline]))
                partial.removeSubrange(...newline)
            }
        }
    }

    /// Completes a trailing line that never got its newline.
    public func flush() {
        lock.withLock {
            guard !partial.isEmpty else { return }
            store(partial)
            partial = ""
        }
    }

    /// Lines with a sequence number above `sequence`, and the sequence
    /// number of the last one (or of the newest line held, if none are new).
    /// Lines that have already been pushed out of the ring are skipped.
    public func lines(after sequence: Int) -> (lines: [String], last: Int) {
        lock.withLock {
            // A cursor from another provider instance can be ahead of ours.
            guard sequence < lastSequence else { return ([], lastSequence) }
            let missing = lastSequence - max(sequence, 0)
            return (Array(lines.suffix(missing)), lastSequence)
        }
    }

    private func store(_ line: String) {
        lines.append("[\(formatter.string(from: Date()))] \(line)")
        lastSequence += 1
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }
}
