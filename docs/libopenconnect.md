# In-process libopenconnect

The VPN session runs inside the privileged helper via libopenconnect, instead
of as an `openconnect` subprocess. Branch: `libopenconnect-shim`.

## Tests

```sh
scripts/test-shim.sh   # shim: marker text -> link state, ESP, drop count, notifications
swift test             # helper: argument validation + real XPC (version, status, observer push);
                       # OpenConnectKit: requestReconnect() re-entering the wrapper (was a deadlock)
```

Not covered: the app-side client's error handling (it needs an enabled
`SMAppService` daemon), and anything involving a real gateway.

## Status

Builds, signs and verifies with `./build.sh`. Verified against public test
hosts only (TLS, certificate rejection, pinning). **Not exercised against a
real gateway:** XPC, helper registration, tunnel bring-up, DTLS/ESP, stats,
reconnect, `vpn-slice`.

## Architecture

| Piece | Role |
|---|---|
| `third_party/` | Git submodules: `openssl` (a release tag, shallow), `openconnect`, `vpnc-scripts`. The pin is the commit each points at. |
| `scripts/build-openconnect.sh` | Builds OpenSSL and libopenconnect from those submodules (static, macOS 27 target) into `vendor/openconnect/`. `OC_ARCHS` picks architectures. |
| `scripts/check-updates.sh` | Reports newer upstream releases/commits for each submodule (exit 1 if any). |
| `Sources/COpenConnectShim` | C wrapper: cookie, `make_cstp_connection`, `setup_tun_device` (runs the vpnc-script), `setup_dtls`, `mainloop`. Commands (cancel, stats, reconnect) go through the library's command pipe. |
| `Sources/OpenConnectKit` | Swift wrapper (`EmbeddedOpenConnect`): one session on its own thread, with log, connected and cert-rejected callbacks. |
| `Sources/PulseVPNMenuHelper/VPNSession.swift` | Hosts the single session in the helper; builds the `SessionStatus`, samples counters once a second, notifies observers; sets `PATH` so `vpn-slice` is found. |
| `Sources/PulseVPNMenuHelper/ObserverHub.swift`, `RequestValidation.swift` | Pushes status to connected apps; checks the arguments the app sends. |
| `Sources/OCShimProbe` | Manual harness: `sudo .build/release/OCShimProbe <url> <cookie> [script] [pin-sha256:…]`. |

### XPC protocol

Calls (app → helper), all one-shot and typed:
`protocolVersion`, `startSession`, `sessionStatus`, `stopSession`,
`requestReconnect`, plus the four route calls. There is at most one session,
so no handle is passed. The session outlives the app; a relaunched app finds
it with `sessionStatus` and reattaches once the counters are seen advancing.

- **`SessionStatus`** (JSON `Data`): `state` (`none` / `running` / `exited`),
  `exitCode`, `startedAt`, `certFailure`, and the `SessionSnapshot` while
  running. One value for both `sessionStatus` replies and pushed changes, so
  adding a field never touches the protocol.
- **Pushed changes:** the app exports a `SessionObserverProtocol` on its side
  of the same connection; the helper calls `sessionStatusChanged(_:)` when the
  session starts, ends, or its link state, ESP flag, drop count or tunnel
  changes. Counters are not pushed (they change every second): the helper
  refreshes them once a second, and the app reads them with `sessionStatus`
  at the interval the user chose.
- **Version check:** `PrivilegedHelperConstants.protocolVersion` (bump it on
  any incompatible change). The app calls `protocolVersion` once per XPC
  connection and refuses to connect to a helper that answers differently or
  can't answer (one that predates it), with a message about updating it.
- **Failed calls:** each call installs its own XPC error handler, so a helper
  crash or dropped connection mid-call throws instead of leaving the `await`
  hanging. A dropped connection also triggers a resync (`sessionStatus`),
  since pushed changes may have been missed.

### Argument checks in the helper

The helper runs as root, so it validates what the app sends
(`RequestValidation`): the log path must be exactly
`/Users/<u>/Library/Application Support/Pulse VPN Menu/Logs/current.log` with
no symlinks (and the file is opened `O_NOFOLLOW`), the VPN URL must be
`https://`, and route addresses must be plain IPv4. The vpnc-script is
deliberately **not** restricted: running a user-configured script as root is
how openconnect works, and the profile that holds it is user-writable.

### Certificate pinning

A certificate that fails normal validation is accepted only if it matches the
profile's `pinnedCertHash`. Otherwise the session aborts and reports the
`pin-sha256:…` fingerprint; the app prompts (Cancel is the default), stores
the pin on the profile and retries. A pinned certificate that later changes
prompts again. The profile editor shows the pin with a **Forget** button.

Trust store: OpenSSL is configured with `--openssldir=/etc/ssl`, so normal
validation uses macOS's `/etc/ssl/cert.pem`. That file does **not** include
CAs added to the keychain (e.g. a corporate root); such a gateway will hit
the pin prompt.

## Build

```sh
git submodule update --init --depth 1 third_party/openssl   # (the build scripts do this for you)
brew install autoconf automake libtool   # build-time only
./build.sh --install                     # builds libopenconnect first
```

`swift build` needs `vendor/` to exist, so run `scripts/build-openconnect.sh`
first on a fresh checkout.

## Keeping dependencies current

Three things are vendored as submodules; each pin is the commit the submodule
points at, so an update is a normal reviewable diff.

| Submodule | Tracks | Currently |
|---|---|---|
| `third_party/openssl` | a release in the 3.5 series (long-term support), shallow clone | `openssl-3.5.9` |
| `third_party/openconnect` | a tested snapshot of upstream `master` (move to a release tag when one has what you need) | `v9.21-25-g70d1e79d` |
| `third_party/vpnc-scripts` | upstream `master` (it has no releases) | `ce9e961` |

```sh
scripts/check-updates.sh       # what's newer upstream; prints the bump commands
```

To bump one (the script prints these):

```sh
git -C third_party/openssl fetch --depth 1 origin tag openssl-3.5.10
git -C third_party/openssl checkout openssl-3.5.10
git add third_party/openssl
scripts/build-openconnect.sh   # builds the checked-out version, even before you commit
scripts/test-shim.sh && swift test
# then connect to a real gateway, and commit the changed submodule pointer
```

The build and the update check only initialise a submodule that is missing;
they never reset one you've checked out to try. OpenSSL security releases
need a rebuild and a new app release, since it's linked statically: watch
`openssl/openssl` releases on GitHub. After moving openconnect, also re-check
the log-text matches described under "The one remaining text match".

## Known gaps

- **Helper crash = tunnel loss.** The session shares the helper's process.
- **LGPL.** libopenconnect is statically linked into the helper; relinkability
  needs a decision (e.g. ship it as a dylib). The license text is bundled in
  `Resources/openconnect-COPYING.LGPL`.
- **Cookie rejection** is detected as `-EPERM`, matching the CLI's mapping;
  not yet seen in practice.
- **`vpn-slice` under the helper's `PATH`** is untested.
- **Helper SHA changed**, so the app re-registers it; expect the Login Items
  approval again.
- **Universal builds** (`OC_ARCHS="arm64 x86_64"`) are untested.

## Typed session state (replaces log parsing)

The app no longer parses `current.log`. The shim keeps an `ocshim_snapshot`
that the helper hands over XPC as JSON (`SessionSnapshot`, in
`PulseVPNHelperProtocol`):

| Field | Source |
|---|---|
| `txPackets` / `txBytes` / `rxPackets` / `rxBytes`, `statsSequence` | libopenconnect's stats callback (`oc_stats`) |
| `linkState` (`connecting` / `up` / `reconnecting`), `dropCount` | tunnel setup, `openconnect_set_reconnected_handler`, and the drop markers below |
| `espEstablished` | the "ESP session established" progress line (below) |
| `interfaceName`, `address` | `openconnect_get_ifname()` and `openconnect_get_ip_info()` right after the tunnel is created |

- **App:** `OpenConnectController.handle(_:recordSample:)` takes in each
  `SessionStatus` (pushed, or fetched for the stats timer) and wakes anything
  waiting on it. `waitForStatus` replaces the 500 ms polling loops in
  connect, reconnect and disconnect. Drop/restore notifications come from
  `dropCount` and `linkState`, so a drop shorter than a poll is still
  reported. The stats timer reads `sessionStatus` and records a sample only
  when `statsSequence` changed, timestamped with the helper's `sampledAt`.
  Unexpected session ends are handled off the pushed status, again after any
  action holding `isBusy` finishes, and after a connection loss.
- **Log:** display-only now. The shim no longer prints the CLI-style
  `Configured as…` / `RX:…` lines; it logs one `Tunnel up: …` line and the
  session expiry once. The "hide repeated stats lines" setting was removed
  with the lines it hid.
- **Tunnel identity:** the menu's `utun6, 172.25.…` text, the route gateway
  and the "tunnel is up" check use the snapshot's interface name and address.
  `NetworkInterfaces.findVPNInterface()` (a scan for the first `utun*` with an
  IPv4 address, skipping `100.x`) is gone; it could pick the wrong interface
  next to Tailscale or another VPN.
- **Removed:** `StatsLineClassifier`, the regexes in `StatsParser`
  (`StatsHistory` now just stores samples), the controller's string matching,
  and the tunnel IP / status / expiry / cipher fields, which nothing read.

### The one remaining text match

libopenconnect exposes neither ESP state nor "a reconnect has begun", so the
shim recognises exactly these in its progress callback, in `ocshim.c`
(`note_progress`), and turns them into typed state:

- `"ESP session established"` sets `esp_established`.
- `"detected dead peer"`, `"server closed connection"`, `"failed to reconnect
  to host"`, `"remaining timeout"` mark a drop (one per episode).

If libopenconnect rewords these, ESP gating and drop notifications silently
stop working. A sturdier option is reading `vpninfo->dtls_state` via
`openconnect-internal.h`, at the cost of tying the shim to the pinned
libopenconnect version.

### Trade-offs

- **Counters lag by up to a second** (the helper's sampling interval) plus the
  user's poll interval; state changes are pushed immediately.
- **A lost push is recovered, not retried:** if the helper dies, the app
  learns from the connection drop and resyncs; an event lost any other way
  would only show up at the next `sessionStatus` read.
- **Still text-based, elsewhere:** `RouteManager` reads `dscacheutil` output
  to find a stale hostname route.

## Follow-ups

### Clear cached cookie option

Not implemented. `ConnectionProfile.lastDSID` caches the login cookie, but
almost every connect starts with `The server rejected the DSID cookie;
re-authenticating.` (35 of 42 connects in one log). libopenconnect's cancel
command (`OC_CMD_CANCEL`, sent by Disconnect) logs the session off on the
server, which invalidates the cookie we just saved. The cached cookie is only
useful after a crash or an app relaunch while the session is still up. Each
stale attempt costs a failed handshake and a confusing log line.

To add:

- **Automatic:** clear `lastDSID` after a user-requested Disconnect, so the
  next connect goes straight to browser login. Keep it across reattach and
  unexpected exits, where the session may still be valid.
- **Manual:** a "Clear saved login" button in the connection editor (next to
  the pinned-certificate "Forget" button) and/or a menu item, via
  `ConnectionStore.updateDSID(profileID:dsid: nil)`, for forcing a fresh
  login when a cookie is stuck.
