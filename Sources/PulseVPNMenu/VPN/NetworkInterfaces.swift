import Foundation
import SystemConfiguration

/// Interface and default-gateway discovery, replacing Python's `netifaces`
/// usage in `launcher.py`.
enum NetworkInterfaces {

    /// Returns (interfaceName, ipv4Address) for the first utun/tun
    /// interface with a usable IPv4 address, skipping Tailscale/ZeroTier
    /// addresses (100.x.x.x) so the real VPN interface is found instead.
    /// Direct translation of `launcher.py`'s `find_vpn_interface()` using
    /// POSIX `getifaddrs()`.
    static func findVPNInterface() -> (name: String, ip: String)? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("utun") || name.hasPrefix("tun") else { continue }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let sinAddr = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var sinAddrCopy = sinAddr
            guard inet_ntop(AF_INET, &sinAddrCopy, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = buffer.withUnsafeBufferPointer { ptr -> String in
                let bytes = ptr.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                return String(decoding: bytes, as: UTF8.self)
            }

            if ip.hasPrefix("100.") { continue }
            return (name, ip)
        }
        return nil
    }

    /// Returns the current default IPv4 gateway, via
    /// `SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4")`'s
    /// "Router" key. Replaces `netifaces.gateways()` /
    /// `launcher.py`'s `get_default_gateway()`.
    static func defaultGatewayIP() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "PulseVPNMenu" as CFString, nil, nil) else { return nil }
        guard let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) else { return nil }
        guard let dict = value as? [String: Any] else { return nil }
        return dict["Router"] as? String
    }
}
