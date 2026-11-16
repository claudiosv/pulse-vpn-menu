import Foundation
import Testing

@testable import OpenConnectMenu

@Suite struct ConnectionProfileValidationTests {
    @Test func acceptsAddressesAndRejectsTheRest() {
        #expect(ConnectionProfile.isValidAddress("10.1.2.3"))
        #expect(ConnectionProfile.isValidAddress("2001:db8::1"))
        #expect(!ConnectionProfile.isValidAddress("10.1.2"))
        #expect(!ConnectionProfile.isValidAddress("example.edu"))
        #expect(!ConnectionProfile.isValidAddress(""))
    }

    @Test func acceptsRoutesWithOptionalPrefix() {
        #expect(ConnectionProfile.isValidRoute("169.237.0.0/16"))
        #expect(ConnectionProfile.isValidRoute("10.1.2.3"))
        #expect(ConnectionProfile.isValidRoute("2001:db8::/32"))
        #expect(ConnectionProfile.isValidRoute("10.0.0.0/0"))
        #expect(ConnectionProfile.isValidRoute("10.0.0.0/32"))
        #expect(ConnectionProfile.isValidRoute("::/128"))
    }

    @Test func rejectsBadRoutes() {
        #expect(!ConnectionProfile.isValidRoute("10.0.0.0/33"))
        #expect(!ConnectionProfile.isValidRoute("::/129"))
        #expect(!ConnectionProfile.isValidRoute("10.0.0.0/"))
        #expect(!ConnectionProfile.isValidRoute("10.0.0.0/-1"))
        #expect(!ConnectionProfile.isValidRoute("10.0.0.0/8/8"))
        #expect(!ConnectionProfile.isValidRoute("example.edu"))
        #expect(!ConnectionProfile.isValidRoute(""))
    }

    @Test func acceptsDomainsWithOptionalWildcard() {
        #expect(ConnectionProfile.isValidDomain("example.edu"))
        #expect(ConnectionProfile.isValidDomain("*.cs.ucdavis.edu"))
        #expect(ConnectionProfile.isValidDomain("a-b.example.edu"))
    }

    @Test func rejectsBadDomains() {
        #expect(!ConnectionProfile.isValidDomain("localhost"))        // one label
        #expect(!ConnectionProfile.isValidDomain("10.1.2.3"))         // an address
        #expect(!ConnectionProfile.isValidDomain("-bad.example.edu"))
        #expect(!ConnectionProfile.isValidDomain("bad-.example.edu"))
        #expect(!ConnectionProfile.isValidDomain("a..example.edu"))
        #expect(!ConnectionProfile.isValidDomain("exa mple.edu"))
        #expect(!ConnectionProfile.isValidDomain("*."))
        #expect(!ConnectionProfile.isValidDomain(String(repeating: "a", count: 64) + ".edu"))
    }
}

@Suite struct ConnectionProfileListTests {
    @Test func listsSplitOnCommasAndWhitespace() {
        let profile = ConnectionProfile(
            name: "x", vpnURL: "https://vpn.example.edu",
            splitRoutes: "10.0.0.0/8, 192.168.0.0/16\n172.16.0.1\t1.2.3.4",
            onDemandDomains: "*.cs.ucdavis.edu,example.edu")
        #expect(profile.splitRouteList == ["10.0.0.0/8", "192.168.0.0/16", "172.16.0.1", "1.2.3.4"])
        #expect(profile.onDemandDomainList == ["*.cs.ucdavis.edu", "example.edu"])
        #expect(profile.dnsServerList.isEmpty)
    }

    @Test func tunnelConfigurationCarriesTheLists() {
        let profile = ConnectionProfile(
            name: "x", vpnURL: "https://vpn.example.edu",
            splitRoutes: "10.0.0.0/8", dnsServers: "10.0.0.53", dnsDomains: "example.edu",
            onDemandDomains: "*.example.edu", noDefaultRoute: true, debug: true,
            pinnedCertHash: "pin-sha256:abc")
        let configuration = profile.tunnelConfiguration
        #expect(configuration.profileID == profile.id)
        #expect(configuration.routing.splitRoutes == ["10.0.0.0/8"])
        #expect(!configuration.routing.forceDefaultRoute)
        #expect(configuration.dns?.servers == ["10.0.0.53"])
        #expect(configuration.dns?.domains == ["example.edu"])
        #expect(configuration.onDemandDomains == ["*.example.edu"])
        #expect(configuration.verbose)
        #expect(configuration.pinnedCertHash == "pin-sha256:abc")
    }
}

@Suite struct ConnectionProfileDecodingTests {
    private func decode(_ json: String) throws -> ConnectionProfile {
        try JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8))
    }

    private let id = "4B8E5F2A-6B3D-4C9E-9F11-2D7A8C0E1B34"

    @Test func decodesAMinimalProfile() throws {
        let profile = try decode(#"{"id":"\#(id)","name":"coe","vpnURL":"https://vpn.example.edu"}"#)
        #expect(profile.name == "coe")
        #expect(profile.splitRoutes == nil)
        #expect(profile.onDemandDomains == nil)
        #expect(!profile.noDefaultRoute)
        #expect(!profile.debug)
    }

    @Test func roundTrips() throws {
        let original = ConnectionProfile(
            name: "x", vpnURL: "https://vpn.example.edu", splitRoutes: "10.0.0.0/8",
            onDemandDomains: "*.example.edu", lastDSID: "abc")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ConnectionProfile.self, from: data) == original)
    }

    @Test func migratesAVpnSliceScriptToRoutes() throws {
        let profile = try decode(
            #"{"id":"\#(id)","name":"x","vpnURL":"https://v.example.edu","script":"/opt/homebrew/bin/vpn-slice 169.237.0.0/16 10.1.2.3 host.example.edu"}"#)
        #expect(profile.splitRoutes == "169.237.0.0/16, 10.1.2.3")
    }

    @Test func explicitRoutesWinOverTheLegacyScript() throws {
        let profile = try decode(
            #"{"id":"\#(id)","name":"x","vpnURL":"https://v.example.edu","splitRoutes":"1.2.3.4","script":"vpn-slice 5.6.7.8"}"#)
        #expect(profile.splitRoutes == "1.2.3.4")
    }

    @Test func dropsScriptsThatAreNotVpnSlice() {
        #expect(ConnectionProfile.routes(fromLegacyScript: "/usr/local/bin/my-script 10.0.0.0/8") == nil)
        #expect(ConnectionProfile.routes(fromLegacyScript: nil) == nil)
        #expect(ConnectionProfile.routes(fromLegacyScript: "vpn-slice host.example.edu") == nil)
    }
}
