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
    ///   - keepSession: keep session cookies (those without an expiry, which
    ///     many single sign-on pages use) between runs; see
    ///     `ChromeProcessLauncher.launch`. Chrome is then closed
    ///     cleanly rather than killed, so it can save them.
    ///   - pollInterval: how often to look for the cookie.
    /// - Throws: `FetchError.cancelled` if the user closes Chrome first.
    public static func fetch(
        cookieNamed name: String,
        at url: String,
        profileDir: URL,
        nativeMessagingHosts: [String] = [],
        keepSession: Bool = false,
        pollInterval: Duration = .seconds(1)
    ) async throws -> String {
        let launch = try await ChromeProcessLauncher.launch(
            profileDir: profileDir, nativeMessagingHosts: nativeMessagingHosts, keepSessionCookies: keepSession)
        let client = CDPClient()

        let result: Result<String, Error>
        do {
            result = .success(try await run(
                client: client, launch: launch, cookieNamed: name, at: url,
                closeOtherTabs: keepSession, pollInterval: pollInterval))
        } catch {
            result = .failure(error)
        }
        await launch.shutDown(client: client, gracefully: keepSession)
        return try result.get()
    }

    private static func run(
        client: CDPClient, launch: ChromeProcessLauncher.LaunchResult,
        cookieNamed name: String, at url: String, closeOtherTabs: Bool, pollInterval: Duration
    ) async throws -> String {
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
            if closeOtherTabs {
                // With "continue where you left off" Chrome reopens the last
                // run's tabs, some a moment after startup.
                await closeTabs(except: pageTarget.targetId, client: client)
            }
            let cookiesResult = try await client.send(
                method: "Storage.getCookies", params: [:], sessionId: sessionId).dictionary
            if let cookie = CDPModels.cookies(from: cookiesResult).first(where: { $0.name == name }) {
                return cookie.value
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private static func closeTabs(except keep: String, client: CDPClient) async {
        guard let result = try? await client.send(method: "Target.getTargets").dictionary else { return }
        for target in CDPModels.targets(from: result) where target.type == "page" && target.targetId != keep {
            _ = try? await client.send(method: "Target.closeTarget", params: ["targetId": target.targetId])
        }
    }
}
