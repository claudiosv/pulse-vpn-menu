import Foundation
import SystemConfiguration

/// Default-gateway discovery, replacing Python's `netifaces` usage in
/// `launcher.py`. (The VPN tunnel's own interface and address come from the
/// helper's session snapshot, not from scanning interfaces.)
enum NetworkInterfaces {

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
