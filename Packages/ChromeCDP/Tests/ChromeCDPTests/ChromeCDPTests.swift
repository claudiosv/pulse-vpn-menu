import Foundation
import Testing

@testable import ChromeCDP

@Suite struct CDPModelsTests {
    @Test func parsesTargets() {
        let result: [String: Any] = [
            "targetInfos": [
                ["targetId": "A", "type": "page"],
                ["targetId": "B", "type": "browser"],
                ["type": "page"],  // no id: skipped
            ]
        ]
        let targets = CDPModels.targets(from: result)
        #expect(targets.map(\.targetId) == ["A", "B"])
        #expect(targets.first?.type == "page")
    }

    @Test func parsesCookies() {
        let result: [String: Any] = [
            "cookies": [
                ["name": "DSID", "value": "abc"],
                ["name": "other"],  // no value: skipped
            ]
        ]
        let cookies = CDPModels.cookies(from: result)
        #expect(cookies.count == 1)
        #expect(cookies.first?.name == "DSID")
        #expect(cookies.first?.value == "abc")
    }

    @Test func missingKeysGiveNothing() {
        #expect(CDPModels.targets(from: [:]).isEmpty)
        #expect(CDPModels.cookies(from: [:]).isEmpty)
    }
}

@Suite struct NativeMessagingHostTests {
    @Test func linksInstalledHostsAndSkipsMissingOnes() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let profile = root.appendingPathComponent("profile")
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = source.appendingPathComponent("com.example.host.json")
        try Data("{}".utf8).write(to: manifest)

        // Twice: the second run must leave a correct link alone.
        for _ in 0..<2 {
            ChromeProcessLauncher.linkNativeMessagingHosts(
                ["com.example.host", "com.example.missing"], into: profile, from: source)
        }

        let hosts = profile.appendingPathComponent("NativeMessagingHosts")
        let link = hosts.appendingPathComponent("com.example.host.json")
        #expect(try fileManager.destinationOfSymbolicLink(atPath: link.path) == manifest.path)
        #expect(!fileManager.fileExists(atPath: hosts.appendingPathComponent("com.example.missing.json").path))
    }
}

@Suite struct FreePortTests {
    @Test func picksAUsablePort() throws {
        let port = try FreePort.pick()
        #expect(port > 0)
    }
}

@Suite struct CDPClientTests {
    @Test func sendBeforeConnectFails() async {
        let client = CDPClient()
        await #expect(throws: CDPClient.CDPError.self) {
            try await client.send(method: "Target.getTargets")
        }
    }
}
