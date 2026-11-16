import Foundation
import Testing

@testable import OpenConnectTunnelCore

@Suite struct NetworkAddressesTests {
    @Test func snapshotIsStableAndLeavesOutTunnelsAndLoopback() {
        let first = NetworkAddresses.snapshot()
        #expect(first == NetworkAddresses.snapshot())
        for entry in first.split(separator: ",") {
            #expect(!entry.hasPrefix("lo"))
            #expect(!entry.hasPrefix("utun"))
            #expect(entry.contains("="))
        }
        #expect(first.split(separator: ",").map(String.init) == first.split(separator: ",").map(String.init).sorted())
    }
}
