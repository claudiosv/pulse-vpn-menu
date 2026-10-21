# In-process libopenconnect

The VPN session runs inside the privileged helper via libopenconnect, instead
of as an `openconnect` subprocess. Branch: `libopenconnect-shim`.

## Status

Builds, signs and verifies with `./build.sh`. Verified against public test
hosts only (TLS, certificate rejection, pinning). **Not exercised against a
real gateway:** XPC, helper registration, tunnel bring-up, DTLS/ESP, stats,
reconnect, `vpn-slice`.

## Architecture

| Piece | Role |
|---|---|
| `scripts/build-openconnect.sh` | Builds OpenSSL 3.5.9 and libopenconnect from source (static, macOS 27 target) into `vendor/openconnect/`. `OC_REF` / first argument picks a tag, branch or sha (default `master`); `OC_ARCHS` picks architectures. |
| `Sources/COpenConnectShim` | C wrapper: cookie, `make_cstp_connection`, `setup_tun_device` (runs the vpnc-script), `setup_dtls`, `mainloop`. Commands (cancel, stats, reconnect) go through the library's command pipe. |
| `Sources/OpenConnectKit` | Swift wrapper (`EmbeddedOpenConnect`): one session on its own thread, with log, connected and cert-rejected callbacks. |
| `Sources/PulseVPNMenuHelper/VPNSession.swift` | Hosts the single session in the helper; tracks status for XPC; sets `PATH` so `vpn-slice` is found. |
| `Sources/OCShimProbe` | Manual harness: `sudo .build/release/OCShimProbe <url> <cookie> [script] [pin-sha256:…]`. |

### XPC protocol

`startSession`, `sessionStatus`, `stopSession`, `requestStatsUpdate`,
`requestReconnect` replace the pid-based subprocess calls. There is at most
one session, so no handle is passed. The session outlives the app; a
relaunched app finds it with `sessionStatus` and reattaches after confirming
a fresh stats sample.

The shim prints the status lines the CLI used to (`Configured as …`,
`RX: … TX: …`, `SSL ciphersuite: …`, session expiry), so the app's log
parsing and stats graph are unchanged.

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
brew install autoconf automake libtool   # build-time only
./build.sh --install                     # builds libopenconnect first
OC_REF=v9.21 ./build.sh                  # pin a release
```

`swift build` needs `vendor/` to exist, so run `scripts/build-openconnect.sh`
first on a fresh checkout.

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

- **XPC:** `sessionStatus` now carries the latest snapshot (cheap, cached
  counters); `pollStats` asks libopenconnect for fresh counters and replies
  within ~2 s. `requestStatsUpdate` is gone.
- **App:** `OpenConnectController.apply(_:recordSample:)` folds a snapshot into
  state. The stats timer uses `pollStats` and records a sample only when
  `statsSequence` changed. Drop/restore notifications fire from `dropCount`
  and `linkState`, so a drop shorter than the poll interval is still
  reported. The connect, reconnect and reattach checks read `espEstablished`
  and fresh samples from snapshots.
- **Log:** display-only now. The shim no longer prints the CLI-style
  `Configured as…` / `RX:…` lines; it logs one `Tunnel up: …` line and the
  session expiry once. The "hide repeated stats lines" setting was removed
  with the lines it hid.
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

- **Latency:** drops are noticed on the next status poll (the app's refresh
  tick), not instantly as before.
- **Poll cost:** `pollStats` can block a helper XPC thread for up to 2 s if
  no sample arrives; a concurrent `stopSession` waits for it.
- **Still text-based, elsewhere:** `RouteManager` reads `dscacheutil` output,
  and `NetworkInterfaces` finds the tunnel by interface name. libopenconnect
  knows the tunnel's real interface name, so the latter could be exact.
