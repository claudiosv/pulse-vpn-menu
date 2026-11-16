# Network Extension

The VPN session runs in a **packet tunnel provider** (`NEPacketTunnelProvider`)
packaged as a system extension, instead of in a root LaunchDaemon. Each saved
connection is a VPN configuration, so it appears in **System Settings > VPN**
(and the menu bar VPN item) with its name, status and a switch.

## One-time setup (required before `./build.sh` works)

The Network Extension and System Extension entitlements are restricted: macOS
refuses to launch a binary that claims them without a provisioning profile
that grants them. For Developer ID distribution that means two profiles from
the Apple Developer portal (team `5HN43G3472`):

1. **Identifiers** — create (or edit) two App IDs:
   - `ai.claudio.openconnect` with capabilities **Network Extensions**
     and **System Extension**.
   - `ai.claudio.openconnect.networkextension` with capability **Network
     Extensions**.
2. **Profiles** — create a **Developer ID** provisioning profile for each App
   ID (Distribution > Developer ID, using the Developer ID Application
   certificate) and download them.
3. Save them as `signing/app.provisionprofile` and
   `signing/tunnel.provisionprofile` (`signing/` is git-ignored), or point
   `PULSE_APP_PROFILE` / `PULSE_TUNNEL_PROFILE` at them.

Check what a profile grants with
`security cms -D -i signing/tunnel.provisionprofile | plutil -p -`: its
`Entitlements` must list `packet-tunnel-provider-systemextension` under
`com.apple.developer.networking.networkextension`.

Then:

```sh
./build.sh --notarize --install
```

macOS installs a system extension only from an app in `/Applications`, and
only from a notarized one. For local iteration without notarizing, disable
SIP and run `systemextensionsctl developer on` (which also lifts the
`/Applications` rule).

## First run

1. **Connect** asks to allow the extension: System Settings > General > Login
   Items & Extensions > Network Extensions. Allow it and click Connect again.
2. macOS asks to allow "Pulse VPN Menu" to add VPN configurations. Allow.
3. Log in in the Chrome window as before.

Every build has a new build number, so an updated app replaces the installed
extension on its next Connect (no prompt after the first approval).

Useful commands: `systemextensionsctl list`,
`log stream --predicate 'subsystem == "ai.claudio.openconnect.networkextension"'`.

## How it fits together

| Piece | Role |
|---|---|
| `Sources/PulseVPNTunnel` | The system extension's executable: `NEProvider.startSystemExtensionMode()`. |
| `Sources/PulseVPNTunnelCore/PacketTunnelProvider.swift` | The provider. Starts the libopenconnect session, applies network settings, answers the app's messages. |
| `…/TunnelPlan.swift` | Turns what the server assigned (addresses, split routes, DNS) plus the connection's routing options into `NEPacketTunnelNetworkSettings`. Replaces the vpnc-script and the app's `route` calls. |
| `…/PacketBridge.swift` | Moves packets between `packetFlow` and libopenconnect over a datagram socket pair, adding/stripping the 4-byte utun address-family header libopenconnect expects. |
| `…/TunnelSession.swift`, `LogRing.swift` | Hosts the single session; status, once-a-second counter sampling, in-memory log. |
| `Sources/PulseVPNTunnelProtocol` | Shared by app and extension: identifiers, `TunnelConfiguration`, `TunnelRequest`/`TunnelReply`, `SessionStatus`. |
| `Sources/PulseVPNMenu/Tunnel/TunnelClient.swift` | App side: one `NETunnelProviderManager` per connection, start/stop, polling the provider. |
| `…/SystemExtensionActivator.swift` | Installs/updates the extension (`OSSystemExtensionRequest`). |
| `Resources/Entitlements/` | Entitlements for the app and the extension. |

### libopenconnect

libopenconnect itself is unmodified; the shim (`Sources/COpenConnectShim`) no
longer calls `openconnect_setup_tun_device` (which creates a utun device and
runs the vpnc-script as root — neither is possible in the sandbox). Instead,
after `openconnect_make_cstp_connection` it passes the server's `oc_ip_info`
to a `configure` callback; the provider applies the settings, and returns one
end of the socket pair, which goes to `openconnect_setup_tun_fd`. No script is
ever set, so libopenconnect forks nothing.

The provider's own sockets (TLS and ESP to the server) are kept off the
tunnel by the system, so a full tunnel doesn't loop.

### Routes and DNS

Decided in `TunnelPlan.make`, per connection:

- **Routes** (`splitRoutes`) set: exactly those destinations go through
  the tunnel. This replaces `vpn-slice` scripts; a saved
  `vpn-slice 169.237.0.0/16 …` script is migrated to its address arguments
  (host-name arguments and any other script are dropped — review the field).
- Otherwise, **all traffic**, unless "Use the server's routes" is on and the
  server sends split-include routes.
- The server's split-exclude routes are always honoured.
- DNS: the server's resolvers. Full tunnel: they become the default. Split
  tunnel: they answer only for the server's split-DNS domains (or its search
  domains) and are routed through the tunnel; with no domains they are unused.

A connection can override both: **DNS Servers** replaces the server's
resolvers, and **DNS Domains** sets exactly which domains they answer for
(in a full tunnel too). The Status tab shows the servers in use.

The system removes all of it when the tunnel ends — there is no cleanup code.

### App ↔ extension

- **Start:** `startVPNTunnel(options:)` with the DSID cookie in the options.
  The cookie is never stored in the VPN configuration.
- **Status, counters, log:** a provider can't call the app, so the app polls
  with `sendProviderMessage` (`TunnelRequest.poll`): every 0.3 s while
  connecting, every second once up, and immediately when the provider posts
  the Darwin notification `…tunnel.status-changed` or the system reports an
  `NEVPNStatus` change. A reply carries the `SessionStatus` and the log lines
  after the app's cursor; the app writes them to `Logs/current.log` (the
  extension is sandboxed and can't).
- **End of session:** the provider keeps its final status for up to 1.5 s so
  the app can collect the exit code, certificate failure and last log lines,
  then finishes. If the app missed it, it falls back to
  `fetchLastDisconnectError` (error domain `ai.claudio.openconnect.networkextension`,
  code = errno).
- **Version check:** every reply carries `TunnelConstants.protocolVersion`.

### Switching it on in System Settings

A start from System Settings has no cookie. The provider ends at once with
`needsLoginExitCode`; the app, if running, notices, runs the browser login and
starts the tunnel itself — the switch flips off for a moment, Chrome opens,
and the switch comes back on once you are signed in. If the app is not
running, the connection just fails with "Sign-in required". Switching it
**off** in System Settings works directly.

## Not verified

Built, signed and unit-tested (route/DNS planning, packet framing through a
real socket pair, log ring, message round-trips). **Never run as an installed
extension**: that needs the provisioning profiles above. Untested against a
real system: extension activation and approval, saving configurations,
`setTunnelNetworkSettings`, packets through `packetFlow`, DTLS/ESP inside the
sandbox, the System Settings switch, reattach after relaunch.

Things to watch on the first real run:

- Throughput: every packet crosses a socket pair (one extra copy each way).
  If it matters, the alternative is handing libopenconnect the utun file
  descriptor directly, as WireGuard does.
- A drop that changes the assigned address ends the session (libopenconnect
  refuses the new address) rather than re-applying settings.

## Migrating from the helper daemon

The old root helper is no longer shipped or used. To remove a previously
approved one: System Settings > General > Login Items & Extensions, turn off
"Pulse VPN Menu" under *Allow in the Background*; then
`sudo launchctl bootout system/com.claudiosv.pulse-vpn-menu.helper` if it is
still loaded.
