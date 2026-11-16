import Darwin
import Foundation
import Testing

@testable import ChromeCDP

/// Runs real Chrome: a local page sets a session cookie (one with no expiry),
/// Chrome is closed the way `ChromeCookieFetcher` closes it, started again on
/// the same profile, and the cookie is looked for.
///
/// Opt in: `CHROME_E2E=1 swift test --filter SessionCookieTests`. Needs Google
/// Chrome or Chromium installed; opens visible windows for a few seconds.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CHROME_E2E"] == "1"))
struct SessionCookieTests {
    /// Answers every request with a page that sets `sessionprobe` as a session cookie.
    private final class Server: @unchecked Sendable {
        let port: UInt16
        private let listener: Int32
        private var running = true

        init() throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer -> Int32 in
                    let result = bind(fd, sockaddrPointer, length)
                    listen(fd, 8)
                    getsockname(fd, sockaddrPointer, &length)
                    return result
                }
            }
            guard bound == 0 else { throw FreePort.FreePortError.bindFailed }
            listener = fd
            port = UInt16(bigEndian: address.sin_port)
            Thread.detachNewThread { [self] in serve() }
        }

        private func serve() {
            let body = "<html><body>probe</body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nSet-Cookie: sessionprobe=1; Path=/\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            while running {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                var buffer = [UInt8](repeating: 0, count: 4096)
                _ = recv(client, &buffer, buffer.count, 0)
                _ = response.withCString { send(client, $0, strlen($0), 0) }
                close(client)
            }
        }

        func stop() {
            running = false
            shutdown(listener, SHUT_RDWR)
            close(listener)
        }
    }

    private func hasProbeCookie(_ client: CDPClient) async -> Bool {
        guard let result = try? await client.send(method: "Storage.getCookies").dictionary else { return false }
        return CDPModels.cookies(from: result).contains { $0.name == "sessionprobe" }
    }

    /// One Chrome run on `profile`: optionally visit the cookie-setting page,
    /// report whether the cookie is there at the end, then close Chrome.
    private func run(profile: URL, keep: Bool, visit port: UInt16?) async throws -> Bool {
        let launch = try await ChromeProcessLauncher.launch(profileDir: profile, keepSessionCookies: keep)
        let client = CDPClient()
        await client.connect(to: launch.webSocketDebuggerURL)

        if let port {
            let targets = try await client.send(method: "Target.getTargets").dictionary
            let page = try #require(CDPModels.targets(from: targets).first { $0.type == "page" })
            let attached = try await client.send(
                method: "Target.attachToTarget", params: ["targetId": page.targetId, "flatten": true]).dictionary
            let session = try #require(attached["sessionId"] as? String)
            _ = try await client.send(
                method: "Page.navigate", params: ["url": "http://127.0.0.1:\(port)/"], sessionId: session)
        }
        var found = false
        for _ in 0..<20 {
            if await hasProbeCookie(client) { found = true; break }
            try await Task.sleep(for: .milliseconds(500))
        }
        await launch.shutDown(client: client, gracefully: keep)
        // Let Chrome release the profile before the next run.
        try await Task.sleep(for: .seconds(1))
        return found
    }

    private func temporaryProfile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("chromecdp-\(UUID().uuidString)")
    }

    @Test func sessionCookieSurvivesARestartWhenKept() async throws {
        _ = try ChromeLocator.locate()
        let server = try Server()
        defer { server.stop() }
        let profile = temporaryProfile()
        defer {
            if ProcessInfo.processInfo.environment["CHROME_E2E_KEEP"] == "1" {
                print("PROFILE \(profile.path)")
            } else {
                try? FileManager.default.removeItem(at: profile)
            }
        }

        #expect(try await run(profile: profile, keep: true, visit: server.port), "the page should set the cookie")
        #expect(try await run(profile: profile, keep: true, visit: nil), "the session cookie should still be there")
    }

    @Test func sessionCookieIsDroppedByDefault() async throws {
        _ = try ChromeLocator.locate()
        let server = try Server()
        defer { server.stop() }
        let profile = temporaryProfile()
        defer { try? FileManager.default.removeItem(at: profile) }

        #expect(try await run(profile: profile, keep: false, visit: server.port), "the page should set the cookie")
        #expect(!(try await run(profile: profile, keep: false, visit: nil)), "the session cookie should be gone")
    }
}
