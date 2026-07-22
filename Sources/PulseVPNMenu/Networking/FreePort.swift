import Foundation

/// Picks a free local TCP port by binding to port 0 and reading back the
/// assigned port, mirroring nodriver's `free_port()`
/// (`nodriver/core/util.py`). Same tolerated race condition as upstream:
/// the socket is closed before Chrome binds the same port.
enum FreePort {
    enum FreePortError: Error {
        case socketCreationFailed
        case bindFailed
        case getsocknameFailed
    }

    static func pick() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FreePortError.socketCreationFailed }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw FreePortError.bindFailed }
        guard listen(fd, 5) == 0 else { throw FreePortError.bindFailed }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getNameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getsockname(fd, sockaddrPtr, &len)
            }
        }
        guard getNameResult == 0 else { throw FreePortError.getsocknameFailed }
        return UInt16(bigEndian: boundAddr.sin_port)
    }
}
