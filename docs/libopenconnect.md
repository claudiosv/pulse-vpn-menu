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
