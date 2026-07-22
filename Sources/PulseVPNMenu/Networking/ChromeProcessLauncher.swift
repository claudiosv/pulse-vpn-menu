import Foundation

/// Launches Chrome with remote debugging enabled and waits for its DevTools
/// HTTP endpoint to come up, mirroring `nodriver.Browser.start()`
/// (`nodriver/core/browser.py`).
enum ChromeProcessLauncher {
    struct LaunchResult {
        let process: Process
        let webSocketDebuggerURL: URL
    }

    enum LaunchError: Error, CustomStringConvertible {
        case devToolsNotResponding
        case invalidVersionResponse

        var description: String {
            switch self {
            case .devToolsNotResponding: return "Chrome's DevTools endpoint never responded."
            case .invalidVersionResponse: return "Chrome's /json/version response was not understood."
            }
        }
    }

    private struct VersionResponse: Decodable {
        let webSocketDebuggerUrl: String
    }

    static func launch(profileDir: URL) async throws -> LaunchResult {
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let chromePath = try ChromeLocator.locate()
        let port = try FreePort.pick()

        let process = Process()
        process.executableURL = chromePath
        process.arguments = [
            "--remote-allow-origins=*",
            "--no-first-run",
            "--no-service-autorun",
            "--no-default-browser-check",
            "--homepage=about:blank",
            "--no-pings",
            "--password-store=basic",
            "--disable-infobars",
            "--disable-breakpad",
            "--disable-dev-shm-usage",
            "--disable-session-crashed-bubble",
            "--disable-search-engine-choice-screen",
            "--disable-features=IsolateOrigins,site-per-process",
            "--user-data-dir=\(profileDir.path)",
            "--remote-debugging-host=127.0.0.1",
            "--remote-debugging-port=\(port)",
            "--window-size=800,900",
        ]
        // Detach Chrome's own output; we only care about the CDP endpoint.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()

        do {
            let wsURL = try await pollForWebSocketURL(port: port)
            return LaunchResult(process: process, webSocketDebuggerURL: wsURL)
        } catch {
            process.terminate()
            throw error
        }
    }

    /// Initial 0.25s delay, then up to 5 tries with 0.5s between — matches
    /// `Browser.start()`'s polling loop exactly.
    private static func pollForWebSocketURL(port: UInt16) async throws -> URL {
        try await Task.sleep(nanoseconds: 250_000_000)

        let versionURL = URL(string: "http://127.0.0.1:\(port)/json/version")!
        var lastError: Error?

        for attempt in 0..<5 {
            do {
                let (data, _) = try await URLSession.shared.data(from: versionURL)
                let response = try JSONDecoder().decode(VersionResponse.self, from: data)
                guard let wsURL = URL(string: response.webSocketDebuggerUrl) else {
                    throw LaunchError.invalidVersionResponse
                }
                return wsURL
            } catch {
                lastError = error
                if attempt < 4 {
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError ?? LaunchError.devToolsNotResponding
    }
}
