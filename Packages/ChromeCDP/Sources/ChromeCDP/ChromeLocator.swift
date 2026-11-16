import Foundation

/// Locates a Chrome/Chromium executable to drive via CDP, mirroring
/// nodriver's `find_chrome_executable()` (`nodriver/core/config.py`).
public enum ChromeLocator {
    public enum ChromeLocatorError: Error, CustomStringConvertible {
        case notFound
        public var description: String {
            "Could not find a Chrome or Chromium browser. Please install Google Chrome or Chromium."
        }
    }

    public static func locate() throws -> URL {
        let fixedCandidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
        ]
        for path in fixedCandidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let pathNames = ["google-chrome", "chromium", "chromium-browser", "chrome", "google-chrome-stable"]
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                for name in pathNames {
                    let candidate = "\(dir)/\(name)"
                    if FileManager.default.isExecutableFile(atPath: candidate) {
                        return URL(fileURLWithPath: candidate)
                    }
                }
            }
        }

        throw ChromeLocatorError.notFound
    }
}
