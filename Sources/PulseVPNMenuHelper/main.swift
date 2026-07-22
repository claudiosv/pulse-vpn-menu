import Foundation
import PulseVPNHelperProtocol

// This process is launched by launchd (per the LaunchDaemon plist
// registered via SMAppService) already running as root, listening for XPC
// connections on the Mach service named below. No RunAtLoad/KeepAlive in
// the plist — launchd starts this on demand, the first time the app's
// NSXPCConnection looks up the service name.
let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: PrivilegedHelperConstants.machServiceName)
listener.delegate = delegate
listener.setConnectionCodeSigningRequirement(PrivilegedHelperConstants.mainAppRequirement)
listener.resume()
RunLoop.current.run()
