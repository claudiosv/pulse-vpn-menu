import Foundation
import Testing

/// `ocshim.c` recognises link drops and "ESP session established" by matching
/// libopenconnect's log text. If a submodule update rewords one of those
/// lines, the shim would stop noticing silently; this fails instead.
@Suite struct LogMarkerTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The text the shim looks for: `drop_markers` plus the ESP line.
    private static func markers() throws -> [String] {
        let shim = try String(
            contentsOf: root.appendingPathComponent("Sources/COpenConnectShim/ocshim.c"), encoding: .utf8)
        let start = try #require(shim.range(of: "drop_markers[] = {"))
        let end = try #require(shim.range(of: "};", range: start.upperBound..<shim.endIndex))
        let list = shim[start.upperBound..<end.lowerBound]
        var found = list.split(separator: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        found.append("ESP session established")
        return found
    }

    /// The shim compares `openconnect_get_dtls_state()` with a copy of
    /// libopenconnect's internal `DTLS_CONNECTED` value.
    @Test func dtlsConnectedValueMatchesTheVendoredSource() throws {
        let header = Self.root.appendingPathComponent("third_party/openconnect/openconnect-internal.h")
        guard let internalHeader = try? String(contentsOf: header, encoding: .utf8) else { return }   // no submodule
        let shim = try String(
            contentsOf: Self.root.appendingPathComponent("Sources/COpenConnectShim/ocshim.c"), encoding: .utf8)

        func value(of name: String, in text: String) -> Int? {
            for line in text.split(separator: "\n") {
                let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if words.count >= 3, words[0] == "#define", words[1] == name { return Int(words[2]) }
            }
            return nil
        }
        let upstream = try #require(value(of: "DTLS_CONNECTED", in: internalHeader))
        let ours = try #require(value(of: "OCSHIM_DTLS_CONNECTED", in: shim))
        #expect(upstream == ours, "DTLS_CONNECTED changed to \(upstream); update OCSHIM_DTLS_CONNECTED")
    }

    @Test func markersAreStillInTheVendoredSource() throws {
        let source = Self.root.appendingPathComponent("third_party/openconnect")
        guard let files = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil) else {
            return
        }
        var text = ""
        for case let url as URL in files where url.pathExtension == "c" {
            text += ((try? String(contentsOf: url, encoding: .utf8)) ?? "").lowercased()
        }
        // Submodule not checked out: nothing to compare against.
        guard !text.isEmpty else { return }

        let markers = try Self.markers()
        #expect(markers.count >= 5)
        for marker in markers {
            #expect(text.contains(marker.lowercased()), "libopenconnect no longer logs \"\(marker)\"")
        }
    }
}
