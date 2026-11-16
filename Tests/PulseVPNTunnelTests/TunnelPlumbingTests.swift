import Darwin
import Foundation
import PulseVPNTunnelProtocol
import Testing
@testable import PulseVPNTunnelCore

/// Stands in for `NEPacketTunnelFlow`: hands out queued packets one read at
/// a time and records what is written back.
private final class FakeFlow: @unchecked Sendable {
    private let lock = NSLock()
    private var outbound: [[Data]]
    private var parked: (@Sendable ([Data], [NSNumber]) -> Void)?
    let written: AsyncStream<(Data, Int32)>
    private let continuation: AsyncStream<(Data, Int32)>.Continuation

    init(outbound: [[Data]]) {
        self.outbound = outbound
        (written, continuation) = AsyncStream.makeStream()
    }

    func read(_ completion: @escaping @Sendable ([Data], [NSNumber]) -> Void) {
        let batch: [Data]? = lock.withLock {
            if outbound.isEmpty {
                parked = completion   // like the real flow: nothing to read yet
                return nil
            }
            return outbound.removeFirst()
        }
        if let batch { completion(batch, batch.map { _ in NSNumber(value: AF_INET) }) }
    }

    func write(_ packets: [Data], _ protocols: [NSNumber]) {
        for (packet, family) in zip(packets, protocols) {
            continuation.yield((packet, family.int32Value))
        }
    }
}

private func ipv4Packet(_ payload: [UInt8]) -> Data { Data([0x45, 0, 0, 0] + payload) }
private func ipv6Packet(_ payload: [UInt8]) -> Data { Data([0x60, 0, 0, 0] + payload) }

/// One datagram from the library's end, waiting briefly for it to arrive.
private func receive(_ fd: Int32) -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: 2048)
    for _ in 0..<200 {
        let length = recv(fd, &buffer, buffer.count, 0)
        if length >= 0 { return Array(buffer[..<length]) }
        usleep(5000)
    }
    return nil
}

@Suite struct PacketBridgeTests {
    @Test func framesPacketsFromTheSystemLikeAUtunDevice() throws {
        let flow = FakeFlow(outbound: [
            [ipv4Packet([1, 2, 3]), Data([0x15, 9]), ipv6Packet([7])],   // the middle one isn't IP
            [ipv4Packet([4])],
        ])
        let bridge = try PacketBridge(readPackets: flow.read, writePackets: flow.write)
        defer { bridge.stop() }
        bridge.start()

        // 4-byte address family in network byte order, then the packet.
        #expect(receive(bridge.libraryFD) == [0, 0, 0, UInt8(AF_INET), 0x45, 0, 0, 0, 1, 2, 3])
        #expect(receive(bridge.libraryFD) == [0, 0, 0, UInt8(AF_INET6), 0x60, 0, 0, 0, 7])
        #expect(receive(bridge.libraryFD) == [0, 0, 0, UInt8(AF_INET), 0x45, 0, 0, 0, 4])
    }

    @Test func unframesPacketsFromTheLibrary() async throws {
        let flow = FakeFlow(outbound: [])
        let bridge = try PacketBridge(readPackets: flow.read, writePackets: flow.write)
        defer { bridge.stop() }
        bridge.start()

        let framed: [[UInt8]] = [
            [0, 0, 0, UInt8(AF_INET), 0x45, 0, 0, 0, 42],
            [0, 0, 0, 99, 1, 2, 3],                          // unknown family: dropped
            [0, 0, 0, UInt8(AF_INET6), 0x60, 0, 0, 0, 43],
        ]
        for datagram in framed {
            #expect(send(bridge.libraryFD, datagram, datagram.count, 0) == datagram.count)
        }

        var iterator = flow.written.makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first.0 == ipv4Packet([42]) && first.1 == AF_INET)
        let second = try #require(await iterator.next())
        #expect(second.0 == ipv6Packet([43]) && second.1 == AF_INET6)
    }

    @Test func carriesAFullSizePacket() throws {
        let big = ipv4Packet([UInt8](repeating: 0xAB, count: 1496))   // 1500 bytes
        let flow = FakeFlow(outbound: [[big]])
        let bridge = try PacketBridge(readPackets: flow.read, writePackets: flow.write)
        defer { bridge.stop() }
        bridge.start()
        #expect(receive(bridge.libraryFD)?.count == 1504)
    }
}

@Suite struct LogRingTests {
    @Test func joinsPiecesIntoLinesAndServesThemBySequence() {
        let ring = LogRing()
        ring.append("Connected to ")
        #expect(ring.lines(after: 0).lines.isEmpty)       // no newline yet
        ring.append("203.0.113.9\nESP session")
        ring.append(" established\n")

        let all = ring.lines(after: 0)
        #expect(all.last == 2)
        #expect(all.lines.map { String($0.dropFirst(26)) } == ["Connected to 203.0.113.9", "ESP session established"])
        #expect(all.lines[0].hasPrefix("[20"))            // timestamped

        #expect(ring.lines(after: 1).lines.count == 1)
        #expect(ring.lines(after: 2).lines.isEmpty)
        // A cursor from an earlier provider instance is ahead of this ring.
        #expect(ring.lines(after: 500).last == 2)

        ring.append("no newline")
        ring.flush()
        #expect(ring.lines(after: 2).lines.count == 1)
    }

    @Test func dropsTheOldestLinesPastCapacityWithoutLosingCount() {
        let ring = LogRing(capacity: 3)
        for index in 1...10 { ring.append("line \(index)\n") }
        let all = ring.lines(after: 0)
        #expect(all.last == 10)
        #expect(all.lines.map { String($0.dropFirst(26)) } == ["line 8", "line 9", "line 10"])
        #expect(ring.lines(after: 9).lines.map { String($0.dropFirst(26)) } == ["line 10"])
    }
}

@Suite struct TunnelSessionTests {
    @Test func aSessionThatNeverStartedStillReportsWhy() {
        let session = TunnelSession()
        #expect(session.status().state == .none)
        session.fail(exitCode: TunnelConstants.needsLoginExitCode, message: "Sign-in required")
        let status = session.status()
        #expect(status.state == .exited)
        #expect(status.exitCode == TunnelConstants.needsLoginExitCode)
        #expect(session.log.lines(after: 0).lines.count == 1)
        #expect(!session.isRunning)
    }
}

@Suite struct WireFormatTests {
    @Test func configurationSurvivesTheProviderConfigurationDictionary() {
        let configuration = TunnelConfiguration(
            profileID: UUID(), vpnURL: "https://vpn.example.edu/emp", pinnedCertHash: "pin-sha256:abc",
            verbose: true, routing: RoutingOptions(splitRoutes: ["10.0.0.0/8"], forceDefaultRoute: false),
            dns: DNSOptions(servers: ["10.0.0.53"], domains: ["example.edu"])
        )
        #expect(TunnelConfiguration(providerConfiguration: configuration.providerConfiguration()) == configuration)
        #expect(TunnelConfiguration(providerConfiguration: nil) == nil)

        // One saved before DNS options existed still loads.
        let old = Data(#"{"profileID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","vpnURL":"https://v","verbose":false,"routing":{"splitRoutes":[],"forceDefaultRoute":true}}"#.utf8)
        #expect(TunnelConfiguration(providerConfiguration: ["configuration": old])?.dns == nil)
        #expect(TunnelConfiguration(providerConfiguration: ["configuration": Data("{}".utf8)]) == nil)
    }

    @Test func messagesRoundTrip() throws {
        let request = TunnelRequest(.reconnect, afterLog: 17)
        let requestData = try #require(request.encoded())
        #expect(TunnelRequest.decode(requestData) == request)
        #expect(TunnelRequest.decode(Data("nope".utf8)) == nil)

        let reply = TunnelReply(
            status: SessionStatus(
                state: .exited, exitCode: -EPERM, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                certFailure: CertFailure(reason: "self-signed certificate", hash: "pin-sha256:abc")),
            logLines: ["[2026-11-16 09:00:00.000] hello"], lastLogSequence: 18
        )
        let replyData = try #require(reply.encoded())
        let decoded = try #require(TunnelReply.decode(replyData))
        #expect(decoded == reply)
        #expect(decoded.protocolVersion == TunnelConstants.protocolVersion)
    }
}
