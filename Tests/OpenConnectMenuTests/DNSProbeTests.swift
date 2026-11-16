import Darwin
import Foundation
import Testing

@testable import OpenConnectMenu

/// A UDP socket on localhost that answers every datagram as a DNS server
/// would: the same id, with the response bit and the given response code.
private final class FakeDNSServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32

    init(responseCode: UInt8 = 0) throws {
        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                let result = bind(socketFD, sockaddrPointer, length)
                getsockname(socketFD, sockaddrPointer, &length)
                return result
            }
        }
        guard bound == 0 else { throw DNSProbeTestError.bindFailed }
        fd = socketFD
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [fd] in
            var buffer = [UInt8](repeating: 0, count: 512)
            while true {
                var from = sockaddr_storage()
                var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let count = withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength)
                    }
                }
                if count < 12 { return }   // closed
                var reply = Array(buffer.prefix(count))
                reply[2] |= 0x80
                reply[3] = (reply[3] & 0xF0) | responseCode
                _ = withUnsafePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, reply, reply.count, 0, $0, fromLength)
                    }
                }
            }
        }
    }

    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }
}

private enum DNSProbeTestError: Error { case bindFailed }

@Suite struct DNSProbeTests {
    @Test func buildsAnNSQueryForTheName() {
        let packet = DNSProbe.query(id: 0x1234, name: "ucdavis.edu")
        #expect(Array(packet.prefix(4)) == [0x12, 0x34, 0x01, 0x00])   // id, recursion desired
        #expect(Array(packet[4..<6]) == [0, 1])                        // one question
        let labels: [UInt8] = [7] + Array("ucdavis".utf8) + [3] + Array("edu".utf8) + [0]
        #expect(Array(packet[12..<(12 + labels.count)]) == labels)
        #expect(Array(packet.suffix(4)) == [0, 2, 0, 1])               // NS, IN
    }

    @Test func rootNameIsASingleZeroByte() {
        let packet = DNSProbe.query(id: 1, name: ".")
        #expect(packet.count == 12 + 1 + 4)
        #expect(packet[12] == 0)
    }

    @Test func readsTheResponseCodeOfAMatchingAnswer() {
        var answer = DNSProbe.query(id: 7, name: "example.edu")
        answer[2] |= 0x80
        answer[3] = 3
        #expect(DNSProbe.responseCode(of: answer, matching: 7) == 3)
        #expect(DNSProbe.responseCode(of: answer, matching: 8) == nil)               // someone else's
        #expect(DNSProbe.responseCode(of: DNSProbe.query(id: 7, name: "a.b"), matching: 7) == nil)   // a query
        #expect(DNSProbe.responseCode(of: [1, 2, 3], matching: 7) == nil)             // too short
    }

    @Test func aServerThatAnswersIsReportedWithItsTime() async throws {
        let server = try FakeDNSServer()
        defer { server.stop() }
        let result = await DNSProbe.probe(
            server: "127.0.0.1", name: "ucdavis.edu", port: String(server.port), attempts: 2, interval: 1)
        #expect(result.answered)
        #expect(result.responseCode == 0)
        #expect(result.summary.contains("answered in"))
        #expect(result.summary.contains("NOERROR"))
    }

    @Test func anErrorResponseStillCountsAsReachable() async throws {
        let server = try FakeDNSServer(responseCode: 3)
        defer { server.stop() }
        let result = await DNSProbe.probe(
            server: "127.0.0.1", name: "nope.example.edu", port: String(server.port), attempts: 1, interval: 1)
        #expect(result.answered)
        #expect(result.summary.contains("NXDOMAIN"))
    }

    @Test func aPortNobodyListensOnIsReportedAsNoAnswer() async throws {
        // Find a UDP port that is free right now, then leave it unused.
        let probeSocket = socket(AF_INET, SOCK_DGRAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(probeSocket, $0, length)
                getsockname(probeSocket, $0, &length)
            }
        }
        let port = UInt16(bigEndian: address.sin_port)
        close(probeSocket)

        let result = await DNSProbe.probe(
            server: "127.0.0.1", name: "ucdavis.edu", port: String(port), attempts: 1, interval: 0.5)
        #expect(!result.answered)
        #expect(result.summary.contains("did not answer"))
    }

    @Test func aNameThatIsNotAnAddressIsRejected() async {
        let result = await DNSProbe.probe(server: "dns.example.edu", name: ".", attempts: 1, interval: 0.2)
        #expect(!result.answered)
        #expect(result.problem == "not an IP address")
    }
}
