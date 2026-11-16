import Darwin
import Foundation

/// Carries IP packets between the system's packet flow
/// (`NEPacketTunnelProvider.packetFlow`) and libopenconnect, which wants a
/// file descriptor that behaves like a utun device.
///
/// A datagram socket pair does that: libopenconnect gets `libraryFD` and
/// reads/writes one packet per datagram, each prefixed with the 4-byte
/// address family (network byte order) a utun device uses; this side adds
/// and strips that prefix.
///
/// The flow is passed as two closures rather than an `NEPacketTunnelFlow`
/// so the bridge can be tested without a provider.
public final class PacketBridge: @unchecked Sendable {
    public typealias ReadPackets = @Sendable (@escaping @Sendable ([Data], [NSNumber]) -> Void) -> Void
    public typealias WritePackets = @Sendable ([Data], [NSNumber]) -> Void

    public enum BridgeError: Error, LocalizedError {
        case socketPair(Int32)

        public var errorDescription: String? {
            switch self {
            case .socketPair(let code): return "Could not create the packet socket pair: \(String(cString: strerror(code)))"
            }
        }
    }

    /// The end to give libopenconnect. Closed by `stop()`.
    public let libraryFD: Int32

    private let localFD: Int32
    private let readPackets: ReadPackets
    private let writePackets: WritePackets
    private let queue = DispatchQueue(label: "com.claudiosv.pulse-vpn-menu.tunnel.bridge")
    private var source: DispatchSourceRead?
    private let lock = NSLock()
    private var stopped = false

    /// Largest datagram: a jumbo packet plus the family prefix.
    private static let maxDatagram = 9000 + 4
    /// How much either direction may queue before packets are dropped.
    private static let socketBuffer: Int32 = 4 * 1024 * 1024
    /// Packets handed to the system per wakeup, so one burst can't starve
    /// everything else on the queue.
    private static let maxBatch = 128

    public init(readPackets: @escaping ReadPackets, writePackets: @escaping WritePackets) throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw BridgeError.socketPair(errno)
        }
        for fd in fds {
            // The defaults (a few kB) would cap the datagram size below the
            // MTU and drop anything beyond a couple of queued packets.
            var size = Self.socketBuffer
            while size >= 64 * 1024 {
                let sent = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
                let received = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
                if sent == 0, received == 0 { break }
                size /= 2
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        libraryFD = fds[0]
        localFD = fds[1]
        self.readPackets = readPackets
        self.writePackets = writePackets
    }

    /// Starts moving packets in both directions.
    public func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: localFD, queue: queue)
        source.setEventHandler { [weak self] in self?.drainFromLibrary() }
        let fd = localFD
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
        pumpFromSystem()
    }

    /// Stops both directions and closes both ends. Call only once
    /// libopenconnect has finished with `libraryFD`.
    public func stop() {
        let alreadyStopped = lock.withLock {
            defer { stopped = true }
            return stopped
        }
        guard !alreadyStopped else { return }
        if let source {
            source.cancel()   // closes localFD
        } else {
            close(localFD)
        }
        close(libraryFD)
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    // MARK: - System -> VPN

    private func pumpFromSystem() {
        readPackets { [weak self] packets, _ in
            guard let self, !self.isStopped else { return }
            self.queue.async {
                // Once libopenconnect has stalled for a whole wait, the rest
                // of this batch is dropped without waiting again.
                var stalled = false
                for packet in packets where !self.sendToLibrary(packet, wait: !stalled) {
                    stalled = true
                }
                // Only one read may be outstanding at a time.
                self.pumpFromSystem()
            }
        }
    }

    /// False only if the packet was dropped because the socket stayed full.
    private func sendToLibrary(_ packet: Data, wait: Bool) -> Bool {
        guard let version = packet.first.map({ $0 >> 4 }), packet.count + 4 <= Self.maxDatagram else { return true }
        let family: Int32
        switch version {
        case 4: family = AF_INET
        case 6: family = AF_INET6
        default: return true
        }
        var prefix = UInt32(family).bigEndian
        return packet.withUnsafeBytes { body in
            withUnsafeMutableBytes(of: &prefix) { head in
                var parts = [
                    iovec(iov_base: head.baseAddress, iov_len: 4),
                    iovec(iov_base: UnsafeMutableRawPointer(mutating: body.baseAddress), iov_len: body.count),
                ]
                // libopenconnect is briefly behind: wait a little (which
                // slows the sender down) rather than drop at once.
                for _ in 0..<(wait ? 20 : 1) {
                    if isStopped { return true }
                    if writev(localFD, &parts, 2) >= 0 { return true }
                    guard errno == ENOBUFS || errno == EAGAIN || errno == EINTR else { return true }
                    if wait { usleep(500) }
                }
                return false
            }
        }
    }

    // MARK: - VPN -> system

    private func drainFromLibrary() {
        var buffer = [UInt8](repeating: 0, count: Self.maxDatagram)
        var packets: [Data] = []
        var protocols: [NSNumber] = []

        while packets.count < Self.maxBatch {
            let length = buffer.withUnsafeMutableBytes { recv(localFD, $0.baseAddress, $0.count, 0) }
            guard length > 4 else {
                if length < 0, errno == EINTR { continue }
                break   // EAGAIN (drained), a closed socket, or a runt
            }
            let family = Int32(buffer[0]) << 24 | Int32(buffer[1]) << 16 | Int32(buffer[2]) << 8 | Int32(buffer[3])
            guard family == AF_INET || family == AF_INET6 else { continue }
            packets.append(Data(buffer[4..<length]))
            protocols.append(NSNumber(value: family))
        }
        // Anything left over makes the read source fire again.
        if !packets.isEmpty, !isStopped {
            writePackets(packets, protocols)
        }
    }
}
