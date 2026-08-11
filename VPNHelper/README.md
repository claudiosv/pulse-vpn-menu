# VPN Helper — SwiftUI

A functional SwiftUI port of the macOS liquid-glass VPN redesign. All
networking is **simulated** — no real VPN/openconnect is invoked. A timer
fakes traffic stats and log lines so every control is live.

## Files

| File | Role |
|------|------|
| `VPNHelperApp.swift` | `@main` app entry — `Window` + `MenuBarExtra` |
| `Models.swift` | `VPNConnection`, `GeneralSettings`, `LogLine`, `Tab` |
| `VPNStore.swift` | `ObservableObject` holding all state + simulated connect/stats |
| `ContentView.swift` | Window shell: segmented tab picker + active tab |
| `StatusView.swift` | Power button, status, switcher, stats, `TrafficGraph`, log |
| `ConnectionsView.swift` | Connection cards with Connect / Edit / Delete + Add |
| `GeneralView.swift` | Preferences (poll interval, disconnect-on-quit, hide stats) |
| `EditConnectionSheet.swift` | Add / Edit sheet (edits a local copy) |
| `MenuBarView.swift` | Lean menu bar dropdown |

## Running it

1. Xcode → **File ▸ New ▸ Project ▸ macOS ▸ App** (Interface: SwiftUI, name it `VPNHelper`).
2. Delete the generated `ContentView.swift` and the `…App.swift`.
3. Drag all files from `VPNHelper/` into the project.
4. Deployment target **macOS 14.0+** (uses `MenuBarExtra`, two-arg `onChange`, `@Observable`-era APIs).
5. Build & Run.

Light/dark follow the system appearance automatically (the HTML mockup's
manual toggle isn't needed on a native app — flip it in System Settings ▸
Appearance, or add a `.preferredColorScheme` for testing).

## Notes / next steps

- Real integration point is `VPNStore.connect(_:)` / `disconnect()` — swap the
  simulated body for a process launch of `openconnect` (e.g. via a privileged
  helper) and feed real stats into `downSamples` / `upSamples`.
- Connections are in-memory only; persist with `Codable` + `UserDefaults` or a
  file in Application Support if you want them to survive relaunch.
