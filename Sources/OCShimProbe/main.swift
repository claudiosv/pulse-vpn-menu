import Foundation
import OpenConnectKit

// Manual probe for the in-process libopenconnect path, with no Network
// Extension and no root: it goes as far as the server assigning addresses,
// prints them, and then gives libopenconnect a socket that leads nowhere
// (no interface is created, so no traffic flows). Good for checking TLS,
// certificate pinning, cookie handling, ESP negotiation and reconnects.
//   .build/release/OCShimProbe <vpn-url> <cookie> [pin-sha256:...] [-v]
// Ctrl-C cancels (clean teardown); stats are polled every 5 s.

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: OCShimProbe <vpn-url> <cookie> [pin-sha256:...] [-v]\n".utf8))
    exit(64)
}

@Sendable func out(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
}

// One end goes to libopenconnect; the other is never read, so packets from
// the server queue up and are then dropped.
var fds: [Int32] = [-1, -1]
guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
    perror("socketpair")
    exit(1)
}
let libraryFD = fds[0]

let oc = EmbeddedOpenConnect(handlers: OpenConnectHandlers(
    log: { level, line in out("[log \(level)] " + line.trimmingCharacters(in: .newlines)) },
    configureTunnel: { config in
        out("[configure] \(config)")
        return libraryFD
    },
    certRejected: { reason, hash in out("[cert rejected] \(reason) \(hash ?? "")") }
))

let pin = args.dropFirst(3).first { $0.hasPrefix("pin-sha256:") }
let done = DispatchSemaphore(value: 0)
oc.start(url: args[1], cookie: args[2], pinnedCert: pin, verbose: args.contains("-v")) { rc in
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
    oc.requestStats()   // returns at once; the sample lands in the snapshot a moment later
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        guard let r = oc.snapshot() else { return }
        out("[stats] link \(r.linkState) esp \(r.espEstablished) drops \(r.dropCount) address \(r.address ?? "-") tx \(r.txPackets) pkts/\(r.txBytes) B rx \(r.rxPackets) pkts/\(r.rxBytes) B")
    }
}
ticker.resume()

DispatchQueue.global().async {
    done.wait()
    exit(0)
}
dispatchMain()
