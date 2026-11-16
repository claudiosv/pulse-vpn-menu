import Darwin
import Foundation
import SystemConfiguration

/// The IPv4 addresses of the Mac's physical interfaces, and a watch that
/// fires when they may have changed. `NWPath` says which interface and
/// gateway are in use but not the local address, so a DHCP renewal that
/// hands out a new address on the same interface goes unnoticed without this.
public enum NetworkAddresses {
    /// Interfaces that are not the physical network: the tunnel itself, the
    /// loopback, and the system's own helper interfaces.
    private static let ignoredPrefixes = ["utun", "lo", "awdl", "llw", "bridge", "gif", "stf", "anpi", "ap", "ipsec"]

    /// `en0=192.168.1.5,en1=...`, sorted, so two snapshots compare equal
    /// exactly when no address changed. IPv6 is left out on purpose: its
    /// temporary addresses rotate on their own and would cause needless
    /// reconnects.
    public static func snapshot() -> String {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return "" }
        defer { freeifaddrs(list) }

        var found: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0
            else { continue }
            let name = String(cString: interface.ifa_name)
            guard !ignoredPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
            if result == 0 { found.append("\(name)=\(String(cString: host))") }
        }
        return found.sorted().joined(separator: ",")
    }
}

/// Calls `onChange` (on a background queue) whenever the system's network
/// configuration reports an IPv4 change. Many reports are false alarms, so
/// callers compare `NetworkAddresses.snapshot()` themselves.
public final class NetworkAddressWatcher: @unchecked Sendable {
    private var store: SCDynamicStore?
    private let queue = DispatchQueue(label: "ai.claudio.openconnect.networkextension.addresses")
    private let onChange: @Sendable () -> Void

    /// Nil if the system configuration store can't be reached (the
    /// extension's sandbox may forbid it); callers then rely on `NWPath`.
    public init?(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange

        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkAddressWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let store = SCDynamicStoreCreate(nil, "OpenConnect Menu" as CFString, callback, &context) else {
            return nil
        }
        let patterns = ["State:/Network/Interface/.*/IPv4", "State:/Network/Global/IPv4"]
        guard SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray),
              SCDynamicStoreSetDispatchQueue(store, queue)
        else { return nil }
        self.store = store
    }

    public func stop() {
        guard let store else { return }
        SCDynamicStoreSetDispatchQueue(store, nil)
        self.store = nil
    }
}
