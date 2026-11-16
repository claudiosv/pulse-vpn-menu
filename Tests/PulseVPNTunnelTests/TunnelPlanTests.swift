import Foundation
import NetworkExtension
import OpenConnectKit
import PulseVPNTunnelProtocol
import Testing
@testable import PulseVPNTunnelCore

@Suite struct TunnelPlanTests {
    private let server = OpenConnectNetworkConfig(
        gatewayAddress: "203.0.113.9", address: "172.25.228.228", netmask: "255.255.255.255",
        dnsServers: ["10.0.0.53", "not-an-address"], domains: ["example.edu"], mtu: 1400
    )

    private func plan(_ server: OpenConnectNetworkConfig, _ routing: RoutingOptions = RoutingOptions()) throws -> TunnelPlan {
        try TunnelPlan.make(server: server, routing: routing, fallbackRemoteAddress: "vpn.example.edu")
    }

    @Test func sendsEverythingThroughTheTunnelByDefault() throws {
        let plan = try plan(server)
        #expect(plan.isFullTunnel)
        #expect(plan.remoteAddress == "203.0.113.9")
        #expect(plan.ipv4?.address == "172.25.228.228")
        #expect(plan.ipv4?.included == [.default])
        #expect(plan.ipv6 == nil)
        #expect(plan.dnsServers == ["10.0.0.53"])          // the malformed one is dropped
        #expect(plan.matchDomains == nil)                   // default resolver
        #expect(plan.mtu == 1400)
    }

    @Test func forcedDefaultRouteOverridesTheServersSplitRoutes() throws {
        var server = server
        server.splitIncludes = ["10.0.0.0/255.0.0.0"]
        #expect(try plan(server).ipv4?.included == [.default])
    }

    @Test func usesTheServersSplitRoutesWhenNotForced() throws {
        var server = server
        server.splitIncludes = ["10.1.2.3/255.0.0.0", "192.168.5.0/24", "fd00::/8", "garbage"]
        server.splitExcludes = ["10.9.0.0/16"]
        server.splitDNS = ["corp.example.edu"]
        let plan = try plan(server, RoutingOptions(forceDefaultRoute: false))

        #expect(!plan.isFullTunnel)
        // Normalised to network addresses; the resolver is routed too.
        #expect(plan.ipv4?.included == [
            .init(address: "10.0.0.0", mask: "255.0.0.0"),
            .init(address: "192.168.5.0", mask: "255.255.255.0"),
            .init(address: "10.0.0.53", mask: "255.255.255.255"),
        ])
        #expect(plan.ipv4?.excluded == [.init(address: "10.9.0.0", mask: "255.255.0.0")])
        #expect(plan.matchDomains == ["corp.example.edu"])
    }

    @Test func noServerRoutesMeansFullTunnelEvenWhenNotForced() throws {
        #expect(try plan(server, RoutingOptions(forceDefaultRoute: false)).isFullTunnel)
    }

    @Test func theConnectionsOwnRoutesWinOverEverything() throws {
        var server = server
        server.splitIncludes = ["10.0.0.0/8"]
        server.netmask = "255.255.255.0"
        let plan = try plan(server, RoutingOptions(splitRoutes: ["169.237.0.0/16", " 10.1.2.3 ", "host.example.edu"]))

        #expect(!plan.isFullTunnel)
        #expect(plan.ipv4?.included == [
            .init(address: "169.237.0.0", mask: "255.255.0.0"),
            .init(address: "10.1.2.3", mask: "255.255.255.255"),
            .init(address: "172.25.228.0", mask: "255.255.255.0"),   // the tunnel's own subnet
            .init(address: "10.0.0.53", mask: "255.255.255.255"),
        ])
        // Without split-DNS domains the search domains decide what the
        // tunnel's resolver answers.
        #expect(plan.matchDomains == ["example.edu"])
    }

    @Test func handlesIPv6() throws {
        let server = OpenConnectNetworkConfig(netmask6: "2001:db8::5/64", dnsServers: ["2001:db8::53"])
        let full = try plan(server)
        #expect(full.ipv4 == nil)
        #expect(full.ipv6?.address == "2001:db8::5")
        #expect(full.ipv6?.prefixLength == 64)
        #expect(full.ipv6?.included == [.default])
        #expect(full.remoteAddress == "vpn.example.edu")

        let split = try plan(server, RoutingOptions(splitRoutes: ["fd00:1::/32"]))
        #expect(split.ipv6?.included == [
            .init(address: "fd00:1::", prefixLength: 32),
            .init(address: "2001:db8::53", prefixLength: 128),
        ])
    }

    @Test func refusesAServerThatAssignsNothingUsable() {
        #expect(throws: TunnelPlan.PlanError.noUsableAddress) {
            try plan(OpenConnectNetworkConfig(address: "nonsense", dnsServers: ["10.0.0.53"]))
        }
    }

    @Test func rejectsMalformedRoutes() {
        for bad in ["", "10.0.0", "10.0.0.0/33", "10.0.0.0/-1", "10.0.0.0/x", "-inet6", "fd00::/64"] {
            #expect(TunnelPlan.parseRoute4(bad) == nil, "\(bad)")
        }
        for bad in ["", "fd00::/129", "10.0.0.0/8", "fd00::/x"] {
            #expect(TunnelPlan.parseRoute6(bad) == nil, "\(bad)")
        }
        #expect(TunnelPlan.parseRoute4("0.0.0.0/0") == .default)
    }

    @Test func buildsNetworkExtensionSettings() throws {
        var server = server
        server.splitIncludes = ["10.0.0.0/8"]
        server.splitDNS = ["corp.example.edu"]
        let settings = try plan(server, RoutingOptions(forceDefaultRoute: false)).networkSettings()

        #expect(settings.tunnelRemoteAddress == "203.0.113.9")
        #expect(settings.mtu == 1400)
        #expect(settings.ipv4Settings?.addresses == ["172.25.228.228"])
        #expect(settings.ipv4Settings?.subnetMasks == ["255.255.255.255"])
        #expect(settings.ipv4Settings?.includedRoutes?.map(\.destinationAddress) == ["10.0.0.0", "10.0.0.53"])
        #expect(settings.ipv4Settings?.includedRoutes?.map(\.destinationSubnetMask) == ["255.0.0.0", "255.255.255.255"])
        #expect(settings.ipv6Settings == nil)
        #expect(settings.dnsSettings?.servers == ["10.0.0.53"])
        #expect(settings.dnsSettings?.matchDomains == ["corp.example.edu"])
        #expect(settings.dnsSettings?.searchDomains == ["example.edu"])

        let full = try plan(self.server).networkSettings()
        #expect(full.ipv4Settings?.includedRoutes?.map(\.destinationAddress) == ["0.0.0.0"])
        #expect(full.dnsSettings?.matchDomains == nil)
    }
}
