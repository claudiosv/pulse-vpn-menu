import Foundation

/// Writes the session log lines collected from the packet tunnel provider to
/// `Logs/current.log`, which `LogStore` tails. (The provider is sandboxed and
/// cannot write there itself; its lines arrive already timestamped.)
///
/// The file is kept roughly bounded: past `capBytes` it is cut back to the
/// most recent half, at a line boundary. `LogStore` copes with it shrinking.
@MainActor
enum SessionLogFile {
    private static let capBytes = 1_048_576

    static func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let url = AppPaths.currentLogFile
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o644])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        handle.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        if size > UInt64(capBytes) {
            trim(url)
        }
    }

    private static func trim(_ url: URL) {
        guard let data = try? Data(contentsOf: url), data.count > capBytes / 2 else { return }
        var tail = data.suffix(capBytes / 2)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail.suffix(from: tail.index(after: newline))
        }
        try? Data(tail).write(to: url)
    }
}
