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
from System Settings (`OpenConnectController.clearSavedLogin`). The connection
editor also has a "Saved login" row with a Clear button.

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
gateways, and the IPv4 addresses of the physical interfaces
(`NetworkAddresses.snapshot()`; IPv6 is left out because its temporary
addresses rotate on their own). `NetworkAddressWatcher`, an `SCDynamicStore`
watch on the IPv4 keys, triggers the comparison, so a DHCP renewal on the same
interface and gateway is noticed. If the extension's sandbox refuses the store,
the provider logs that and falls back to `NWPath` alone; not yet checked in a
live session.

### 4. Connect on demand (Done)

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

Done: `ConnectionProfile.onDemandDomains` (editor section "Connect on
Demand", same list format and wildcard handling as the DNS domains) is carried
in `TunnelConfiguration.onDemandDomains`. `TunnelClient.applyOnDemand` installs
one `NEEvaluateConnectionRule(matchDomains:andAction: .connectIfNeeded)` plus a
final ignore rule. A user disconnect turns the rules off
(`TunnelClient.suspendOnDemand`) until the next connect or app launch.
Limits: `.connectIfNeeded` fires only when the name can't be resolved without
the VPN, so a name that also resolves publicly won't trigger it (there is no
"always connect for this domain" action); and the app has to be running to
sign in, otherwise the start gives up after the 180 s wait. The editor says
so. For `*.cs.ucdavis.edu` this means internal-only hosts work and public ones
don't: `login.cs.ucdavis.edu` has no public address, while `cs.ucdavis.edu` and
`www.cs.ucdavis.edu` do resolve (checked with `dig`), so those two never
trigger it. Closing the gap would need a different mechanism (a probe URL on
an `NEOnDemandRuleConnect` reacts to unreachability, not to lookups) and was
not attempted.

## Correctness and robustness

### 5. Read ESP state directly (Done)

"ESP session established" and link drops are detected by matching
libopenconnect's log text (`note_progress` in `ocshim.c`). If upstream
rewords a line, ESP gating and drop notifications silently stop working.
Reading `vpninfo->dtls_state` through `openconnect-internal.h` is sturdier,
at the cost of tying the shim to the pinned libopenconnect version.

Done, without the internal header (it needs the per-arch `config.h` from the
build cache and ties the shim tightly to the build). Instead
`scripts/patches/oc-dtls-state.patch` adds one function,
`openconnect_get_dtls_state()`, to libopenconnect; `build-openconnect.sh`
applies it to its cached copy of the pinned source and stops if it no longer
applies after a submodule bump. The shim polls it on every stats sample and
sets the ESP flag from it, so ESP is noticed even if the log line is reworded.
The state value it compares with (`DTLS_CONNECTED`, 5) is internal, so
`LogMarkerTests` checks it against `third_party/openconnect`.

Link drops still rely on log text (`drop_markers`; libopenconnect has no state
for them), and `LogMarkerTests` fails if any of those strings, or the ESP line
the shim still uses as a fast path, is no longer in the vendored source. That
test found a marker the pinned version never logs (`server closed
connection`); the shim now matches `read error on` and `ssl connection
failure` instead.

### 6. Don't require ESP to call the tunnel connected (Done)

Connect waits up to 30 s for ESP (`OpenConnectController.isTunnelUp`). If UDP
4500 is blocked, the session falls back to TLS and works, but the app reports
`tunnelTimeout`. Treat "tunnel up, ESP not established after the server's
fallback interval" as connected, and show which transport is in use.

Done: connect waits `OpenConnectController.espGrace` (12 s) for ESP, then
accepts a link that is up over TLS and logs it. The Status tab shows
"ESP (UDP)" or "TLS (TCP)".

### 7. Trust CAs from the keychain (Done)

Certificate validation uses `/etc/ssl/cert.pem` only, so a gateway whose
certificate chains to a corporate root in the keychain always hits the pin
prompt. When OpenSSL's validation fails, evaluate the peer chain with
`SecTrust` before falling back to the pin.

Where: `validate_peer_cert` in `ocshim.c`, with a new callback into Swift.

Done: the shim's new `trust_chain` callback hands the chain to
`SystemTrust.trusts(chain:host:)` (`SecTrust` with the SSL policy for the
server's name) before the pin prompt. Not tried against a real corporate root.

### 8. Session expiry warning (Done)

libopenconnect reports when the login expires
(`openconnect_get_auth_expiration`); it is logged once and never shown. Carry
it in `SessionSnapshot`, show it on the Status tab, and post a notification
shortly before it runs out.

Done: the expiry travels in `SessionSnapshot.expiresAt`, shows as "LOGIN
expires …" on the Status tab (orange within an hour), and a notification is
scheduled 10 minutes before (gated by the "unexpected disconnect"
notification setting).

## Cleanup

### 9. Remove the old helper daemon automatically (Done)

The retired root helper (`com.claudiosv.pulse-vpn-menu.helper`) stays
registered until switched off by hand in Login Items. On first launch the app
could call `SMAppService.daemon(plistName:).unregister()` once.

Done: `LegacyHelperCleanup` runs once at launch. The helper's launchd plist is
bundled again (`Resources/LegacyHelper`, copied by `build.sh`) because
`SMAppService` needs it to find the service.

Limit, found on the first machine it ran on: where the system has lost the link
between the old registration and the app, `SMAppService` reports `.notFound`
and `unregister()` fails with "Operation not permitted". The app then logs the
manual command (`sudo launchctl bootout system/com.claudiosv.pulse-vpn-menu.helper`)
once and stops trying. The automatic path only helps where the registration is
still visible to `SMAppService`.

### 10. Rename the internals (Done)

The bundle identifiers are `ai.claudio.openconnect[.networkextension]`, but
targets, source paths, the app name and the notary keychain profile still said
`PulseVPN…` / `pulse-vpn-menu`. Pick one name.

Done: the name is "OpenConnect Menu". The app is `OpenConnect Menu.app`; the
targets and source directories are `OpenConnectMenu`, `OpenConnectTunnel`,
`OpenConnectTunnelCore`, `OpenConnectTunnelProtocol` (and their tests); the
extension's principal class is `OpenConnectPacketTunnelProvider`. The data
folder `~/Library/Application Support/Pulse VPN Menu` is moved to `OpenConnect
Menu` on first launch (`AppPaths`), which carries the saved connections, logs
and the Chrome login profile. Deliberately unchanged:
- the bundle identifiers (fixed by the provisioning profiles);
- the retired helper's identifiers (`com.claudiosv.pulse-vpn-menu.helper`,
  `PulseVPNMenuHelper`), which name the old service to remove;
- the `pulse-vpn-menu-notarytool` keychain profile, a stored credential that
  can only be recreated with `notarytool store-credentials` and an app-specific
  password;
- the `PULSE_…` environment variables in `build.sh` and `notarize.sh`, and the
  repository directory name.

### 11. Tests for the app target (Done)

The tunnel side has unit tests; the app has none. Worth covering first:
`ConnectionProfile` decoding (including the `vpn-slice` migration),
`isValidRoute`, `isValidAddress`, `isValidDomain`.

Done: `Tests/OpenConnectMenuTests`.

## Only if needed

### 13. Throughput

Every packet crosses a socket pair between `packetFlow` and libopenconnect
(`PacketBridge`), one extra copy each way. If measurements show it matters,
hand libopenconnect the system's utun file descriptor directly, as WireGuard
does. That relies on finding the descriptor by scanning, not on public API.

Measured (details and how to rerun: [bridge-benchmark.md](bridge-benchmark.md);
Apple M4 Pro, 1400-byte packets): the bridge moves
about 12 Gbit/s from the system to libopenconnect and 14 Gbit/s the other
way, against 18 Gbit/s for a bare socket pair with no bridge. That is far
above what the ESP/TLS transport can encrypt, so the bridge is not the limit
and this item is not worth doing. The benchmark leaves out
`NEPacketTunnelFlow` and the VPN transport; an end-to-end `iperf3` run
through a real tunnel would be the next measurement if a speed problem shows
up.

### 14. Route by hostname

`vpn-slice host.example.edu` resolved a name over the VPN, routed its address
and wrote an `/etc/hosts` entry; hostname arguments are dropped in migration.
Restoring it means resolving through the tunnel's DNS and re-applying network
settings as addresses change. `/etc/hosts` stays out of reach of the sandbox.

## Suggested order

1 and 3 first: both are small and remove friction on every connect. Then 2,
which unlocks 4.
