#!/usr/bin/env bash
# Build, bundle, and codesign "Pulse VPN Menu.app", including its packet
# tunnel system extension (PulseVPNTunnel, a Network Extension the app
# installs through OSSystemExtensionRequest).
#
# Usage: ./build.sh            build -> dist/Pulse VPN Menu.app
#        ./build.sh --install  also install to /Applications
#        ./build.sh --notarize also notarize + staple (see notarize.sh)
#
# The Network Extension entitlements are restricted: both the app and the
# extension must embed a Developer ID provisioning profile that grants them,
# or macOS refuses to launch either. Put the two profiles at
#   signing/app.provisionprofile      (App ID ai.claudio.openconnect)
#   signing/tunnel.provisionprofile   (App ID ai.claudio.openconnect.networkextension)
# or point PULSE_APP_PROFILE / PULSE_TUNNEL_PROFILE at them. See
# docs/network-extension.md for how to create them. PULSE_ALLOW_MISSING_PROFILES=1
# builds without them, for inspecting the bundle only: it will not run.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Pulse VPN Menu"
BUNDLE_ID="ai.claudio.openconnect"
EXECUTABLE_NAME="PulseVPNMenu"
TUNNEL_EXECUTABLE_NAME="PulseVPNTunnel"
# Must match TunnelConstants.extensionBundleIdentifier.
TUNNEL_BUNDLE_ID="ai.claudio.openconnect.networkextension"
TEAM_ID="5HN43G3472"
VERSION="0.2.0"
# The system replaces an installed system extension only when its version
# differs from the bundled one, so every build gets its own build number.
BUILD_NUMBER="${PULSE_BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"
SIGN_IDENTITY="Developer ID Application: Claudio Spiess (${TEAM_ID})"

APP_PROFILE="${PULSE_APP_PROFILE:-signing/app.provisionprofile}"
TUNNEL_PROFILE="${PULSE_TUNNEL_PROFILE:-signing/tunnel.provisionprofile}"

INSTALL=false
NOTARIZE=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --notarize) NOTARIZE=true ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

HAVE_PROFILES=true
for profile in "${APP_PROFILE}" "${TUNNEL_PROFILE}"; do
    if [[ ! -f "${profile}" ]]; then
        echo "missing provisioning profile: ${profile}" >&2
        HAVE_PROFILES=false
    fi
done
if [[ "${HAVE_PROFILES}" == "false" ]]; then
    if [[ "${PULSE_ALLOW_MISSING_PROFILES:-0}" != "1" ]]; then
        echo "error: the Network Extension entitlements need Developer ID provisioning" >&2
        echo "profiles; see docs/network-extension.md. (PULSE_ALLOW_MISSING_PROFILES=1" >&2
        echo "builds a bundle that can be inspected but will not launch.)" >&2
        exit 1
    fi
    echo "warning: building without provisioning profiles; the result will not launch" >&2
fi

echo "==> Building libopenconnect"
./scripts/build-openconnect.sh

echo "==> swift build -c release"
# `--product` is single-valued (the last one wins), so build each product
# separately; passing both silently skips the app and bundles a stale binary.
for product in "${EXECUTABLE_NAME}" "${TUNNEL_EXECUTABLE_NAME}"; do
    swift build -c release --product "${product}"
done

APP_BUNDLE="dist/${APP_NAME}.app"
# A system extension lives here, in a bundle named after its identifier.
TUNNEL_BUNDLE="${APP_BUNDLE}/Contents/Library/SystemExtensions/${TUNNEL_BUNDLE_ID}.systemextension"
rm -rf dist
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${TUNNEL_BUNDLE}/Contents/MacOS"

echo "==> Copying executables"
cp ".build/release/${EXECUTABLE_NAME}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"
cp ".build/release/${TUNNEL_EXECUTABLE_NAME}" "${TUNNEL_BUNDLE}/Contents/MacOS/${TUNNEL_EXECUTABLE_NAME}"

# Keep symbols for crash reports in dist/dSYMs (outside the bundle), then
# strip the shipped copies. Must happen before codesigning.
echo "==> Extracting dSYMs and stripping"
mkdir -p dist/dSYMs
dsymutil ".build/release/${EXECUTABLE_NAME}" -o "dist/dSYMs/${EXECUTABLE_NAME}.dSYM" 2>/dev/null
dsymutil ".build/release/${TUNNEL_EXECUTABLE_NAME}" -o "dist/dSYMs/${TUNNEL_EXECUTABLE_NAME}.dSYM" 2>/dev/null
strip -x "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"
strip -x "${TUNNEL_BUNDLE}/Contents/MacOS/${TUNNEL_EXECUTABLE_NAME}"

echo "==> Bundling the libopenconnect license"
cp vendor/openconnect/COPYING.LGPL "${APP_BUNDLE}/Contents/Resources/openconnect-COPYING.LGPL"

# The retired root helper's launchd plist, kept only so the app can find and
# unregister that service on first launch (LegacyHelperCleanup). Its
# BundleProgram no longer exists; nothing is ever started from it.
mkdir -p "${APP_BUNDLE}/Contents/Library/LaunchDaemons"
cp Resources/LegacyHelper/com.claudiosv.pulse-vpn-menu.helper.plist \
    "${APP_BUNDLE}/Contents/Library/LaunchDaemons/"

echo "==> Writing Info.plist"
cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright Claudio Spiess.</string>
</dict>
</plist>
PLIST

# NEMachServiceName must be prefixed with one of the app groups in
# Resources/Entitlements/tunnel.entitlements. NEProviderClasses names the
# provider by its Objective-C name: @objc(PulseVPNPacketTunnelProvider) in
# Sources/PulseVPNTunnelCore/PacketTunnelProvider.swift.
echo "==> Writing the system extension's Info.plist"
cat > "${TUNNEL_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME} Tunnel</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME} Tunnel</string>
    <key>CFBundleIdentifier</key>
    <string>${TUNNEL_BUNDLE_ID}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundlePackageType</key>
    <string>SYSX</string>
    <key>CFBundleExecutable</key>
    <string>${TUNNEL_EXECUTABLE_NAME}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright Claudio Spiess.</string>
    <key>NSSystemExtensionUsageDescription</key>
    <string>Carries your VPN traffic to the Pulse Secure / Ivanti server.</string>
    <key>NetworkExtension</key>
    <dict>
        <key>NEMachServiceName</key>
        <string>${TEAM_ID}.${BUNDLE_ID}.tunnel</string>
        <key>NEProviderClasses</key>
        <dict>
            <key>com.apple.networkextension.packet-tunnel</key>
            <string>PulseVPNPacketTunnelProvider</string>
        </dict>
    </dict>
</dict>
</plist>
PLIST

echo "==> Building AppIcon.icns"
if [[ ! -d Assets/AppIcon.iconset ]]; then
    echo "error: Assets/AppIcon.iconset not found" >&2
    exit 1
fi
iconutil -c icns Assets/AppIcon.iconset -o "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

echo "==> Copying menu bar status icons"
cp Assets/menubar-connected.png "${APP_BUNDLE}/Contents/Resources/menubar-connected.png"
cp Assets/menubar-disconnected.png "${APP_BUNDLE}/Contents/Resources/menubar-disconnected.png"

if [[ "${HAVE_PROFILES}" == "true" ]]; then
    echo "==> Embedding provisioning profiles"
    cp "${APP_PROFILE}" "${APP_BUNDLE}/Contents/embedded.provisionprofile"
    cp "${TUNNEL_PROFILE}" "${TUNNEL_BUNDLE}/Contents/embedded.provisionprofile"
fi

# Inside out: the extension first, then the app around it. Not --deep, which
# would re-sign the extension with the app's entitlements.
echo "==> Codesigning system extension: ${TUNNEL_BUNDLE_ID}"
codesign --force --options runtime --timestamp \
    --sign "${SIGN_IDENTITY}" \
    --entitlements Resources/Entitlements/tunnel.entitlements \
    "${TUNNEL_BUNDLE}"

echo "==> Codesigning app: ${BUNDLE_ID}"
codesign --force --options runtime --timestamp \
    --sign "${SIGN_IDENTITY}" \
    --entitlements Resources/Entitlements/app.entitlements \
    "${APP_BUNDLE}"

echo "==> Verifying signatures"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
codesign -d --entitlements - "${TUNNEL_BUNDLE}" 2>/dev/null | head -40

if [[ "${NOTARIZE}" == "true" ]]; then
    ./notarize.sh "${APP_BUNDLE}"
fi

echo
echo "Built: $(pwd)/${APP_BUNDLE}"
echo
echo "Note: macOS only installs a system extension from an app in /Applications,"
echo "and (unless 'systemextensionsctl developer on' is set with SIP disabled) only"
echo "from a notarized one: use --install and --notarize (one-time setup:"
echo "./notarize.sh --store-credentials ...). The first Connect asks to allow the"
echo "extension in System Settings > General > Login Items & Extensions > Network"
echo "Extensions, and then to allow adding VPN configurations."

if [[ "${INSTALL}" == "true" ]]; then
    echo "==> Installing to /Applications"
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP_BUNDLE}" /Applications/
    echo "Installed: /Applications/${APP_NAME}.app"
fi
