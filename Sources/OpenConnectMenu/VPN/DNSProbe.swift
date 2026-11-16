import Darwin
import Foundation

/// Asks a DNS server a real question over UDP and reports whether and how
/// fast it answers. Used right after the tunnel comes up to catch a tunnel
/// that is "connected" but carries no traffic, which otherwise only shows as
/// lookups failing ("Unknown host").
///
/// It runs in the app, not the extension: the extension's own sockets are
/// exempt from the tunnel's routes, so a probe there would not go through it.
enum DNSProbe {
    struct Result: Equatable {
        let server: String
        /// Round trip of the first answer, nil if there was none.
        let milliseconds: Double?
        /// The response code (0 = NOERROR, 3 = NXDOMAIN, ...) of the answer.
        let responseCode: Int?
        /// Why there was no answer, e.g. the socket could not be created.
        let problem: String?

        var answered: Bool { milliseconds != nil }

        /// One log line.
        var summary: String {
            if let milliseconds, let responseCode {
                return "DNS server \(server) answered in \(Int(milliseconds.rounded())) ms (\(Self.codeName(responseCode)))"
            }
            return "DNS server \(server) did not answer\(problem.map { ": \($0)" } ?? "")"
        }

        private static func codeName(_ code: Int) -> String {
            switch code {
            case 0: return "NOERROR"
            case 1: return "FORMERR"
            case 2: return "SERVFAIL"
            case 3: return "NXDOMAIN"
            case 4: return "NOTIMP"
            case 5: return "REFUSED"
            default: return "rcode \(code)"
            }
        }
    }

    /// Sends the query up to `attempts` times, `interval` apart, and returns
    /// at the first answer. Any well-formed reply counts, whatever its
    /// response code: the point is that the server is reachable.
    static func probe(
        server: String, name: String, port: String = "53", attempts: Int = 3, interval: TimeInterval = 2
    ) async -> Result {
        await Task.detached(priority: .utility) {
            run(server: server, name: name, port: port, attempts: attempts, interval: interval)
        }.value
    }

    // MARK: - Query

    /// A recursive query for the NS records of `name` ("." is the root).
    static func query(id: UInt16, name: String) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") where !label.isEmpty {
            let utf8 = Array(label.utf8.prefix(63))
            bytes.append(UInt8(utf8.count))
            bytes.append(contentsOf: utf8)
        }
        bytes.append(0)
        bytes.append(contentsOf: [0, 2, 0, 1])   // type NS, class IN
        return bytes
    }

    /// The response code of `packet` if it is an answer to query `id`.
    static func responseCode(of packet: [UInt8], matching id: UInt16) -> Int? {
        guard packet.count >= 12,
              UInt16(packet[0]) << 8 | UInt16(packet[1]) == id,
              packet[2] & 0x80 != 0   // the QR bit: a response, not a query
        else { return nil }
        return Int(packet[3] & 0x0F)
    }

    private static func run(server: String, name: String, port: String, attempts: Int, interval: TimeInterval) -> Result {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_DGRAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(server, port, &hints, &list) == 0, let info = list else {
            return Result(server: server, milliseconds: nil, responseCode: nil, problem: "not an IP address")
        }
        defer { freeaddrinfo(list) }

        let fd = socket(info.pointee.ai_family, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            return Result(server: server, milliseconds: nil, responseCode: nil, problem: "could not open a socket")
        }
        defer { close(fd) }
        guard connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            return Result(
                server: server, milliseconds: nil, responseCode: nil,
                problem: "no route (\(String(cString: strerror(errno))))")
        }

        let id = UInt16.random(in: 1...UInt16.max)
        let packet = query(id: id, name: name)
        let start = DispatchTime.now()
        var buffer = [UInt8](repeating: 0, count: 1500)

        for _ in 0..<max(attempts, 1) {
            _ = packet.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(interval * 1e9)
            while DispatchTime.now().uptimeNanoseconds < deadline {
                let remaining = Int32((deadline - DispatchTime.now().uptimeNanoseconds) / 1_000_000)
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, max(remaining, 1)) > 0 else { break }
                let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                guard count > 0 else { break }   // e.g. ICMP unreachable reported as an error
                if let code = responseCode(of: Array(buffer.prefix(count)), matching: id) {
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
                    return Result(server: server, milliseconds: elapsed, responseCode: code, problem: nil)
                }
            }
        }
        let seconds = Int((Double(attempts) * interval).rounded())
        return Result(server: server, milliseconds: nil, responseCode: nil, problem: "no reply in \(seconds) s")
    }
}
