import Foundation

/// Drives a real, visible Chrome window via CDP to the VPN login page and
/// waits for the `DSID` session cookie to appear once the user logs in.
/// Direct reimplementation of `launcher.py`'s `fetch_dsid()` (which uses the
/// Python `nodriver` package for the same purpose), confirmed step-by-step
/// against nodriver's vendored source. No WKWebView, no shelling out to
/// Python — Chrome is launched and driven natively from Swift.
actor DSIDAuthenticator {
    enum AuthError: Error, CustomStringConvertible {
        case noPageTarget
        case noSessionId
        case cancelled

        var description: String {
            switch self {
            case .noPageTarget: return "Chrome did not report an initial page target."
            case .noSessionId: return "Could not attach to the Chrome tab."
            case .cancelled: return "Browser login was cancelled (Chrome window closed)."
            }
        }
    }

    func fetchDSID(vpnURL: String) async throws -> String {
        let launch = try await ChromeProcessLauncher.launch(profileDir: AppPaths.chromeProfileDir)
        let client = CDPClient()

        defer {
            launch.process.terminate()
            Task { await client.close() }
        }

        await client.connect(to: launch.webSocketDebuggerURL)

        let targetsResult = try await client.send(method: "Target.getTargets").dictionary
        guard let pageTarget = CDPModels.targets(from: targetsResult).first(where: { $0.type == "page" }) else {
            throw AuthError.noPageTarget
        }

        let attachResult = try await client.send(
            method: "Target.attachToTarget",
            params: ["targetId": pageTarget.targetId, "flatten": true]
        ).dictionary
        guard let sessionId = attachResult["sessionId"] as? String else {
            throw AuthError.noSessionId
        }

        _ = try await client.send(method: "Page.navigate", params: ["url": vpnURL], sessionId: sessionId)

        while true {
            if !launch.process.isRunning {
                throw AuthError.cancelled
            }
            let cookiesResult = try await client.send(method: "Storage.getCookies", params: [:], sessionId: sessionId).dictionary
            if let dsidCookie = CDPModels.cookies(from: cookiesResult).first(where: { $0.name == "DSID" }) {
                return dsidCookie.value
            }
            try await Task.sleep(for: .seconds(1))
        }
    }
}
