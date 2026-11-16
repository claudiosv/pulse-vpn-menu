import Darwin
import Foundation
import Testing

@testable import OpenConnectTunnelCore

/// Throughput of `PacketBridge` on its own: how fast packets cross the
/// socket pair between the system's packet flow and libopenconnect. It leaves
/// out `NEPacketTunnelFlow` itself and the VPN transport, so it is the ceiling
/// the bridge puts on a tunnel, not the speed of a real one.
///
/// Opt in: `BRIDGE_BENCH=1 swift test --filter PacketBridgeBenchmark`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BRIDGE_BENCH"] == "1"))
struct PacketBridgeBenchmark {
    private static let packetSize = 1400
    private static let seconds = 3.0
    private static let batch = 128

    private static func ipv4Packet() -> Data {
        var bytes = [UInt8](repeating: 0xAB, count: packetSize)
        bytes[0] = 0x45
        return Data(bytes)
    }

    private static func report(_ label: String, packets: Int, elapsed: Double) {
        let bits = Double(packets) * Double(packetSize) * 8
        print(String(format: "BENCH %@: %.2f Gbit/s, %.0f kpps (%d packets in %.2fs)",
                     label, bits / elapsed / 1e9, Double(packets) / elapsed / 1000, packets, elapsed))
    }

    /// Reads datagrams from `fd` until told to stop; returns how many.
    private static func receiver(_ fd: Int32, stop: ManagedAtomicFlag) -> Task<Int, Never> {
        Task.detached {
            var buffer = [UInt8](repeating: 0, count: 9004)
            var count = 0
            while !stop.isSet {
                let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if n > 4 { count += 1 } else { usleep(50) }
            }
            return count
        }
    }

    /// System -> VPN: the flow hands over batches as fast as they are taken.
    @Test func systemToLibrary() async throws {
        let packet = Self.ipv4Packet()
        let batchOfPackets = [Data](repeating: packet, count: Self.batch)
        let protocols = [NSNumber](repeating: NSNumber(value: AF_INET), count: Self.batch)
        let stop = ManagedAtomicFlag()
        let bridge = try PacketBridge(
            readPackets: { completion in
                if stop.isSet { return }
                DispatchQueue.global().async { completion(batchOfPackets, protocols) }
            },
            writePackets: { _, _ in })
        let counter = Self.receiver(bridge.libraryFD, stop: stop)
        let start = Date()
        bridge.start()
        try await Task.sleep(for: .seconds(Self.seconds))
        let elapsed = Date().timeIntervalSince(start)
        stop.set()
        let received = await counter.value
        bridge.stop()
        Self.report("system -> libopenconnect", packets: received, elapsed: elapsed)
    }

    /// VPN -> system: libopenconnect writes datagrams as fast as it can.
    @Test func libraryToSystem() async throws {
        let delivered = Counter()
        let stop = ManagedAtomicFlag()
        let bridge = try PacketBridge(
            readPackets: { _ in },
            writePackets: { packets, _ in delivered.add(packets.count) })
        let fd = bridge.libraryFD
        let sender = Task.detached {
            var datagram = [UInt8](repeating: 0xAB, count: Self.packetSize + 4)
            datagram.replaceSubrange(0..<4, with: [0, 0, 0, UInt8(AF_INET)])
            datagram[4] = 0x45
            while !stop.isSet {
                let n = datagram.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
                if n < 0 { usleep(50) }
            }
        }
        let start = Date()
        bridge.start()
        try await Task.sleep(for: .seconds(Self.seconds))
        let elapsed = Date().timeIntervalSince(start)
        stop.set()
        await sender.value
        let total = delivered.value
        bridge.stop()
        Self.report("libopenconnect -> system", packets: total, elapsed: elapsed)
    }

    /// Baseline: the same datagrams over a bare socket pair, no bridge. The
    /// difference to the numbers above is what the bridge itself costs.
    @Test func rawSocketPairBaseline() async throws {
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0)
        for fd in fds {
            var size: Int32 = 4 * 1024 * 1024
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        let stop = ManagedAtomicFlag()
        let counter = Self.receiver(fds[1], stop: stop)
        let (writer, _) = (fds[0], 0)
        let sender = Task.detached {
            let datagram = [UInt8](repeating: 0xAB, count: Self.packetSize + 4)
            while !stop.isSet {
                let n = datagram.withUnsafeBytes { send(writer, $0.baseAddress, $0.count, 0) }
                if n < 0 { usleep(50) }
            }
        }
        let start = Date()
        try await Task.sleep(for: .seconds(Self.seconds))
        let elapsed = Date().timeIntervalSince(start)
        stop.set()
        await sender.value
        let received = await counter.value
        close(fds[0])
        close(fds[1])
        Self.report("raw socketpair (no bridge)", packets: received, elapsed: elapsed)
    }
}

private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) { lock.withLock { count += n } }
    var value: Int { lock.withLock { count } }
}
