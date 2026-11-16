# Possible improvements

Ideas that came out of the Network Extension port, ranked by how much they
would improve daily use. Items marked "Done" are implemented (not yet tested
by hand in the app). File references are where
the change would land.

## Worth doing first

### 1. Stop the wasted first connect attempt (Done)

Disconnecting logs the session off on the server (`OC_CMD_CANCEL`), which
invalidates the DSID cookie the app has just cached in
`ConnectionProfile.lastDSID`. The next connect therefore tries a dead cookie,
fails, and only then opens the browser; the log shows
`The server rejected the DSID cookie; re-authenticating.` on nearly every
connect.

- Clear `lastDSID` after a user-requested disconnect, so the next connect
  goes straight to browser login. Keep it across reattach and unexpected
  exits, where the session may still be valid.
- Optionally add a "Clear saved login" button in the connection editor.

Where: `OpenConnectController.disconnect()`, `ConnectionStore.updateDSID`.
See also "Clear cached cookie option" in [libopenconnect.md](libopenconnect.md).

Done: `lastDSID` is cleared after a disconnect from the app and after a stop
from System Settings (`OpenConnectController.clearSavedLogin`). Not done: the
"Clear saved login" button.

### 2. Connect from System Settings without the flicker (Done)

A start from System Settings > VPN carries no login cookie. Today the
provider fails at once with `needsLoginExitCode`, the app notices, logs in,
and starts the tunnel itself: the switch flips on, off, then on again.

Instead the provider could stay in "Connecting…" and wait for the app to
deliver the cookie in a message, with a timeout if the app isn't running.

Where: `PacketTunnelProvider.startTunnel`, a new `TunnelRequest` operation,
`TunnelClient.connectionStatusChanged`.

Done: the provider stays in "Connecting", reports `SessionStatus.awaitingLogin`
and accepts a `.login` request with the cookie (protocol version 4). It gives
up after `TunnelConstants.loginWait` (180 s). The app signs in and sends the
cookie in `TunnelClient.start` instead of restarting the tunnel.

### 3. Reconnect on wake and network change (Done)

Nothing reacts to sleep, wake or a Wi-Fi switch. The tunnel waits for
dead-peer detection (a probe every 5 s, then libopenconnect's retries) to
notice the link is gone.

- Override `wake()` in the provider and request a reconnect.
- Watch the default path (`NWPathMonitor`) and request a reconnect when the
  interface or its address changes.

Where: `PacketTunnelProvider`, `TunnelSession.requestReconnect()`.

Done: `wake()` and an `NWPathMonitor` (ignoring the tunnel's own interface)
schedule a reconnect after 2 s. The monitor compares status, interfaces and
gateways; a change of IP address on the same interface and gateway is not
detected.

### 4. Connect on demand

Network Extension supports on-demand rules, e.g. connect when a name under
`ucdavis.edu` is looked up, or whenever the Mac is not on a given Wi-Fi
network. It fits split tunneling well. It needed item 2 first, because an
on-demand start has no cookie either; that is now in place.

It must be configurable per connection, as a list of domains that trigger a
connect. The first use is `*.cs.ucdavis.edu`: looking up any name under it
brings the VPN up. Details:

- Setting: an optional list of on-demand domains on `ConnectionProfile` (and
  `TunnelConfiguration`), edited in the connection editor like the DNS
  domains, accepting the same wildcard form (`*.example.edu`). Empty means
  on demand is off for that connection.
- Rules: one `NEEvaluateConnectionRule` with `matchDomains` and the action
  `.connectIfNeeded`, wrapped in an `NEOnDemandRuleEvaluateConnection`, then
  a final `NEOnDemandRuleDisconnect` (or `Ignore`) for everything else. Set
  `manager.isOnDemandEnabled` only when the list is non-empty.
  `matchDomains` matches a domain and everything under it, so strip the
  leading `*.`.
- Interaction with disconnect: a user-requested disconnect must not be
  undone by the next lookup. Either turn on demand off until the user
  connects again, or accept the system's own behavior and say so in the UI.
- An on-demand start has no cookie, so it relies on item 2: the app has to be
  running to sign in, and the 180 s wait applies. Decide what happens when
  the app isn't running (launch it, or post a notification).

Where: `NETunnelProviderManager.onDemandRules` in `TunnelClient.ensureManager`,
plus per-connection settings and UI.

## Correctness and robustness

### 5. Read ESP state directly

"ESP session established" and link drops are detected by matching
libopenconnect's log text (`note_progress` in `ocshim.c`). If upstream
rewords a line, ESP gating and drop notifications silently stop working.
Reading `vpninfo->dtls_state` through `openconnect-internal.h` is sturdier,
at the cost of tying the shim to the pinned libopenconnect version.

### 6. Don't require ESP to call the tunnel connected

Connect waits up to 30 s for ESP (`OpenConnectController.isTunnelUp`). If UDP
4500 is blocked, the session falls back to TLS and works, but the app reports
`tunnelTimeout`. Treat "tunnel up, ESP not established after the server's
fallback interval" as connected, and show which transport is in use.

### 7. Trust CAs from the keychain

Certificate validation uses `/etc/ssl/cert.pem` only, so a gateway whose
certificate chains to a corporate root in the keychain always hits the pin
prompt. When OpenSSL's validation fails, evaluate the peer chain with
`SecTrust` before falling back to the pin.

Where: `validate_peer_cert` in `ocshim.c`, with a new callback into Swift.

### 8. Session expiry warning

libopenconnect reports when the login expires
(`openconnect_get_auth_expiration`); it is logged once and never shown. Carry
it in `SessionSnapshot`, show it on the Status tab, and post a notification
shortly before it runs out.

## Cleanup

### 9. Remove the old helper daemon automatically

The retired root helper (`com.claudiosv.pulse-vpn-menu.helper`) stays
registered until switched off by hand in Login Items. On first launch the app
could call `SMAppService.daemon(plistName:).unregister()` once.

### 10. Rename the internals

The bundle identifiers are `ai.claudio.openconnect[.networkextension]`, but
targets, source paths, the app name and the notary keychain profile still say
`PulseVPN…` / `pulse-vpn-menu`. Pick one name.

### 11. Tests for the app target

The tunnel side has unit tests; the app has none. Worth covering first:
`ConnectionProfile` decoding (including the `vpn-slice` migration),
`isValidRoute`, `isValidAddress`, `isValidDomain`.

### 12. Universal build

`OC_ARCHS="arm64 x86_64"` is supported by `scripts/build-openconnect.sh` but
has never been built or run.

## Only if needed

### 13. Throughput

Every packet crosses a socket pair between `packetFlow` and libopenconnect
(`PacketBridge`), one extra copy each way. If measurements show it matters,
hand libopenconnect the system's utun file descriptor directly, as WireGuard
does. That relies on finding the descriptor by scanning, not on public API.

### 14. Route by hostname

`vpn-slice host.example.edu` resolved a name over the VPN, routed its address
and wrote an `/etc/hosts` entry; hostname arguments are dropped in migration.
Restoring it means resolving through the tunnel's DNS and re-applying network
settings as addresses change. `/etc/hosts` stays out of reach of the sandbox.

## Suggested order

1 and 3 first: both are small and remove friction on every connect. Then 2,
which unlocks 4.
