import Foundation
import OpenConnectKit

// Manual probe for the in-process libopenconnect path. Needs root to bring
// up the tunnel:
//   sudo .build/release/OCShimProbe <vpn-url> <cookie> [vpnc-script]
// Ctrl-C cancels (clean teardown); stats are requested every 5 s.

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: OCShimProbe <vpn-url> <cookie> [vpnc-script]\n".utf8))
    exit(64)
}

@Sendable func out(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
}

let oc = EmbeddedOpenConnect(handlers: OpenConnectHandlers(
    log: { level, line in out("[log \(level)] " + line.trimmingCharacters(in: .newlines)) },
    stats: { s in out("[stats] tx \(s.txPackets) pkts/\(s.txBytes) B  rx \(s.rxPackets) pkts/\(s.rxBytes) B") },
    connected: { t in out("[connected] \(t.address ?? "?")/\(t.netmask ?? "?") gw \(t.gateway ?? "?") mtu \(t.mtu)") }
))

let done = DispatchSemaphore(value: 0)
oc.start(url: args[1], cookie: args[2], vpncScript: args.count > 3 ? args[3] : nil) { rc in
    out("[exit] \(rc)")
    done.signal()
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { oc.cancel() }
sigint.resume()

let ticker = DispatchSource.makeTimerSource(queue: .main)
ticker.schedule(deadline: .now() + 5, repeating: 5)
ticker.setEventHandler { oc.requestStats() }
ticker.resume()

DispatchQueue.global().async {
    done.wait()
    exit(0)
}
dispatchMain()
