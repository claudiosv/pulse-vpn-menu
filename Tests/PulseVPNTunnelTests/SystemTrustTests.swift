import Foundation
import Testing

@testable import PulseVPNTunnelCore

@Suite struct SystemTrustTests {
    @Test func emptyChainIsNotTrusted() {
        #expect(!SystemTrust.trusts(chain: [], host: "vpn.example.edu"))
    }

    @Test func unreadableCertificatesAreNotTrusted() {
        #expect(!SystemTrust.trusts(chain: [Data("not a certificate".utf8)], host: "vpn.example.edu"))
    }
}
