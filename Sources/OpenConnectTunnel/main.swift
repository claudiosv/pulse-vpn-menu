import Foundation
import NetworkExtension
import OpenConnectTunnelCore

// The packet tunnel system extension. The system launches it (as root, in
// the app sandbox) when a VPN configuration that names this bundle starts,
// and instantiates the class named in Info.plist's NEProviderClasses for
// each tunnel. Referencing the class here keeps the linker from dropping it:
// nothing else in this executable mentions it by name.
_ = PacketTunnelProvider.self

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
