import Foundation

/// Opens a visible Chrome window on a page, lets the user log in by hand, and
/// returns the value of a named cookie as soon as it appears.
public enum ChromeCookieFetcher {
    public enum FetchError: Error, CustomStringConvertible {
        case noPageTarget
        case noSessionId
        case cancelled

        public var description: String {
            switch self {
            case .noPageTarget: return "Chrome did not report an initial page target."
            case .noSessionId: return "Could not attach to the Chrome tab."
            case .cancelled: return "Browser login was cancelled (Chrome window closed)."
            }
        }
    }

    /// - Parameters:
    ///   - name: the cookie to wait for.
    ///   - url: the page to open.
    ///   - profileDir: Chrome's user-data directory, kept between runs so the
    ///     browser remembers the user.
    ///   - nativeMessagingHosts: see `ChromeProcessLauncher.launch`.
    ///   - pollInterval: how often to look for the cookie.
    /// - Throws: `FetchError.cancelled` if the user closes Chrome first.
    public static func fetch(
        cookieNamed name: String,
        at url: String,
        profileDir: URL,
        nativeMessagingHosts: [String] = [],
        pollInterval: Duration = .seconds(1)
    ) async throws -> String {
        let launch = try await ChromeProcessLauncher.launch(
            profileDir: profileDir, nativeMessagingHosts: nativeMessagingHosts)
        let client = CDPClient()

        defer {
            launch.process.terminate()
            Task { await client.close() }
        }

        await client.connect(to: launch.webSocketDebuggerURL)

        let targetsResult = try await client.send(method: "Target.getTargets").dictionary
        guard let pageTarget = CDPModels.targets(from: targetsResult).first(where: { $0.type == "page" }) else {
            throw FetchError.noPageTarget
        }

        let attachResult = try await client.send(
            method: "Target.attachToTarget",
            params: ["targetId": pageTarget.targetId, "flatten": true]
        ).dictionary
        guard let sessionId = attachResult["sessionId"] as? String else {
            throw FetchError.noSessionId
        }

        _ = try await client.send(method: "Page.navigate", params: ["url": url], sessionId: sessionId)

        while true {
            if !launch.process.isRunning {
                throw FetchError.cancelled
            }
            let cookiesResult = try await client.send(
                method: "Storage.getCookies", params: [:], sessionId: sessionId).dictionary
            if let cookie = CDPModels.cookies(from: cookiesResult).first(where: { $0.name == name }) {
                return cookie.value
            }
            try await Task.sleep(for: pollInterval)
        }
    }
}
