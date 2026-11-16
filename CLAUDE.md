# OpenConnect Menu — instructions for Claude

## After every commit: build, install, relaunch

After each commit that changes the app or the tunnel extension (anything
under `Sources/`, `Resources/`, `Assets/`, `build.sh` or `Package.swift`),
without asking:

1. `./build.sh --notarize` (several minutes: run it in the background). The
   app stays running meanwhile.
2. Stop the running app: `kill -TERM` the
   `/Applications/OpenConnect Menu.app/Contents/MacOS/OpenConnectMenu` process
   and wait for it to exit. (An AppleScript `quit` is refused.)
3. Replace `/Applications/OpenConnect Menu.app` with `dist/OpenConnect Menu.app`
   and `open` it.
4. Confirm it is running and report the build number.

This is standing permission to upload the build to Apple's notary service
and to overwrite the installed app. A connected VPN survives the relaunch
(the app reattaches); the tunnel extension itself is only replaced on the
next Connect.

Not needed for commits that only touch documentation or tests.

Prerequisites, already set up on this machine: the provisioning profiles in
`signing/` and the `pulse-vpn-menu-notarytool` keychain profile. See
`docs/network-extension.md`.
