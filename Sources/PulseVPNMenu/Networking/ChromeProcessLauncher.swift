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
            let wsURL = try await pollForWebSocketURL(process: process, port: port)
            return LaunchResult(process: process, webSocketDebuggerURL: wsURL)
        } catch {
            process.terminate()
            throw error
        }
    }

    /// Initial 0.25s delay, then polls every 0.5s for up to ~20s total.
    /// Measured Chrome cold-starting its DevTools port on this machine at
    /// ~4s — the original 5-try/~2.5s budget (matching nodriver's
    /// `Browser.start()` exactly) was too tight and caused spurious
    /// "Could not connect to the server" failures. Bails out early if
    /// Chrome's own process has already exited rather than waiting out the
    /// full budget on a browser that's never coming up.
    private static func pollForWebSocketURL(process: Process, port: UInt16) async throws -> URL {
        try await Task.sleep(for: .milliseconds(250))

        let versionURL = URL(string: "http://127.0.0.1:\(port)/json/version")!
        var lastError: Error?

        for attempt in 0..<40 {
            if !process.isRunning {
                throw LaunchError.devToolsNotResponding
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: versionURL)
                let response = try JSONDecoder().decode(VersionResponse.self, from: data)
                guard let wsURL = URL(string: response.webSocketDebuggerUrl) else {
                    throw LaunchError.invalidVersionResponse
                }
                return wsURL
            } catch {
                lastError = error
                if attempt < 39 {
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        throw lastError ?? LaunchError.devToolsNotResponding
    }
}
