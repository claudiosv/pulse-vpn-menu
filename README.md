# Pulse VPN Menu

A native Swift macOS menu bar app for connecting to an Ivanti/Pulse Secure
VPN via `openconnect`. Reimplements the behavior of
[openconnect-pulse-launcher](https://github.com/) (the Python/`rumps`
version of this app) as a SwiftUI `MenuBarExtra` app: it drives a real
Chrome window over the Chrome DevTools Protocol to capture the `DSID`
session cookie, then launches `openconnect --protocol=pulse` as root via the
native macOS administrator-privileges dialog.

## Requirements

- macOS 14 (Sonoma) or later.
- [`openconnect`](https://www.infradead.org/openconnect/) installed (e.g.
  `brew install openconnect`).
- Google Chrome or Chromium installed (used to capture the DSID login
  cookie; a real, visible browser window is used so you can log in with
  your SSO/2FA flow, including any browser extensions like a password
  manager since the profile directory is persistent).

## Building

```shell
./build.sh            # -> dist/Pulse VPN Menu.app, codesigned
./build.sh --install   # also copies it into /Applications
```

The build script compiles with `swift build -c release`, assembles the
`.app` bundle by hand (`Info.plist`, icon, menu bar status images), and
signs it with the `Developer ID Application` identity in your keychain.
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
   - **Logs** — openconnect's full output.
   - **General** — app-wide preferences.
3. On **Connections**, add a connection: give it a name, the VPN URL (e.g.
   `https://vpn.example.edu/emp`), and optionally a vpnc script (e.g.
   `vpn-slice 169.237.0.0/16`), a post-connect command, and route/debug
   toggles.
4. Click **Connect** (in the window, or from the menu bar). A Chrome window
   opens to the VPN login page — log in there. Once the `DSID` session
   cookie appears, Chrome closes and `openconnect` launches (you'll see the
   standard "administrator privileges" password dialog, since VPN routing
   requires root).
5. The **Logs** tab shows openconnect's output from when the connection
   started (persisted across closing the window or relaunching the app).
   **Disconnect**/**Reconnect** act on whichever connection is currently up.

## Project layout

See `Sources/PulseVPNMenu/`, organized by responsibility:
- `App/` — the `MenuBarExtra` app entry point and menu content.
- `Networking/` — the from-scratch Chrome DevTools Protocol client used to
  capture the DSID cookie (no external dependencies — built on
  `URLSessionWebSocketTask`).
- `VPN/` — openconnect process lifecycle, route management, interface/
  gateway discovery, and stats parsing.
- `Privileged/` — the `osascript`/administrator-privileges command runner.
- `Persistence/` — connection profiles, runtime state, and the log store.
- `UI/` — Settings and Logs windows.
