import Foundation
import OpenConnectKit

// Manual probe for the in-process libopenconnect path. Needs root to bring
// up the tunnel:
//   sudo .build/release/OCShimProbe <vpn-url> <cookie> [vpnc-script] [pin-sha256:...] [-v]
// Ctrl-C cancels (clean teardown); stats are polled every 5 s.

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: OCShimProbe <vpn-url> <cookie> [vpnc-script] [pin-sha256:...]\n".utf8))
    exit(64)
}

@Sendable func out(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
}

let oc = EmbeddedOpenConnect(handlers: OpenConnectHandlers(
    log: { level, line in out("[log \(level)] " + line.trimmingCharacters(in: .newlines)) },
    connected: { t in out("[connected] \(t.address ?? "?")/\(t.netmask ?? "?") gw \(t.gateway ?? "?") mtu \(t.mtu)") },
    certRejected: { reason, hash in out("[cert rejected] \(reason) \(hash ?? "")") }
))

let done = DispatchSemaphore(value: 0)
oc.start(url: args[1], cookie: args[2], vpncScript: args.count > 3 ? args[3] : nil, pinnedCert: args.count > 4 && !args[4].isEmpty ? args[4] : nil, verbose: args.contains("-v")) { rc in
    out("[exit] \(rc)")
    done.signal()
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { oc.cancel() }
sigint.resume()

let ticker = DispatchSource.makeTimerSource(queue: .main)
ticker.schedule(deadline: .now() + 5, repeating: 5)
ticker.setEventHandler {
    if let r = oc.pollStats() {
        out("[stats] link \(r.snapshot.linkState) esp \(r.snapshot.espEstablished) drops \(r.snapshot.dropCount) tx \(r.snapshot.txPackets) pkts/\(r.snapshot.txBytes) B rx \(r.snapshot.rxPackets) pkts/\(r.snapshot.rxBytes) B")
    }
}
ticker.resume()

DispatchQueue.global().async {
    done.wait()
    exit(0)
}
dispatchMain()
