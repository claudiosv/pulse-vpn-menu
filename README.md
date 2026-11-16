# Pulse VPN Menu

A native Swift macOS menu bar app for connecting to an Ivanti/Pulse Secure
VPN via `openconnect`. Reimplements the behavior of
[openconnect-pulse-launcher](https://github.com/) (the Python/`rumps`
version of this app) as a SwiftUI `MenuBarExtra` app: it drives a real
Chrome window over the Chrome DevTools Protocol to capture the `DSID`
session cookie, then runs the VPN session inside a Network Extension packet
tunnel (libopenconnect, `--protocol=pulse`, linked in statically — no
`openconnect` binary or Homebrew install needed at runtime). Each connection
shows up in System Settings > VPN. A server certificate that fails validation
prompts once to pin its fingerprint for that connection.

## Requirements

- macOS 27 or later.
- Two Developer ID provisioning profiles granting the Network Extension
  entitlement, in `signing/` — see `docs/network-extension.md`. Without them
  `./build.sh` stops.
- Build-time only: `brew install autoconf automake libtool`. OpenSSL and
  libopenconnect are git submodules in `third_party/`;
  `scripts/build-openconnect.sh` builds them and links the result into the
  tunnel extension (`OC_ARCHS="arm64 x86_64"` for a universal build). Clone with
  `--recurse-submodules` (or run `git submodule update --init`), and see
  `docs/libopenconnect.md` for keeping them up to date.
- Google Chrome or Chromium installed (used to capture the DSID login
  cookie; a real, visible browser window is used so you can log in with
  your SSO/2FA flow, including any browser extensions like a password
  manager since the profile directory is persistent).

## Building

```shell
./build.sh                        # -> dist/Pulse VPN Menu.app, codesigned
./build.sh --notarize --install   # what you need to actually run it
```

The build script compiles with `swift build -c release`, assembles the
`.app` bundle by hand (`Info.plist`, icon, menu bar status images, and the
packet tunnel system extension under `Contents/Library/SystemExtensions`), and
signs it with the `Developer ID Application` identity in your keychain. macOS
only installs the extension from a notarized app in `/Applications`.
LSUIElement is set, so it runs as a menubar-only agent with no Dock icon —
that only applies once it's run from inside the assembled `.app`, not from
the raw `.build/release/PulseVPNMenu` binary.

## Usage

1. Launch the app (menu bar icon appears; no Dock icon).
2. Open the main window from the menu (**Open Pulse VPN Menu…**, or
   **Settings…** / **Logs…** to land on a specific tab). It has four tabs:
   - **Status** — a power button that connects/disconnects the default
     connection, the live tunnel's duration and RX/TX totals, the traffic
     graph, and a peek at recent log activity.
   - **Connections** — add/edit/delete saved connections, pick the default,
     or connect to any of them directly.
   - **Logs** — the VPN session's output.
   - **General** — app-wide preferences.
3. On **Connections**, add a connection: give it a name, the VPN URL (e.g.
   `https://vpn.example.edu/emp`), and optionally the destinations to route
   through the VPN (e.g. `169.237.0.0/16`; blank sends everything), a
   post-connect command, and route/debug toggles.
4. Click **Connect** (in the window, or from the menu bar). A Chrome window
   opens to the VPN login page — log in there. Once the `DSID` session
   cookie appears, Chrome closes and the VPN session starts in the tunnel
   extension (the first time, macOS asks you to allow the extension in
   System Settings > General > Login Items & Extensions > Network Extensions,
   and to allow adding VPN configurations).
5. The **Logs** tab shows the session's output from when the connection
   started (persisted across closing the window or relaunching the app).
   **Disconnect**/**Reconnect** act on whichever connection is currently up.

## Project layout

See `Sources/PulseVPNMenu/`, organized by responsibility:
- `App/` — the `MenuBarExtra` app entry point and menu content.
- `Networking/` — the from-scratch Chrome DevTools Protocol client used to
  capture the DSID cookie (no external dependencies — built on
  `URLSessionWebSocketTask`).
- `VPN/` — session lifecycle (driven through the tunnel extension) and the
  stats history.
- `Tunnel/` — VPN configurations, system extension activation, and the
  client for the packet tunnel provider.
- `Persistence/` — connection profiles, runtime state, and the log store.
- `UI/` — Settings and Logs windows.
