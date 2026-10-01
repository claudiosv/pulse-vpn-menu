#!/usr/bin/env bash
# Build, bundle, and codesign "Pulse VPN Menu.app" (including its
# privileged helper daemon, PulseVPNMenuHelper, registered via SMAppService).
#
# Usage: ./build.sh            build -> dist/Pulse VPN Menu.app
#        ./build.sh --install  also install to /Applications
#        ./build.sh --notarize also notarize + staple (see notarize.sh)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Pulse VPN Menu"
BUNDLE_ID="com.claudiosv.pulse-vpn-menu"
EXECUTABLE_NAME="PulseVPNMenu"
HELPER_EXECUTABLE_NAME="PulseVPNMenuHelper"
HELPER_BUNDLE_ID="com.claudiosv.pulse-vpn-menu.helper"
VERSION="0.1.0"
SIGN_IDENTITY="Developer ID Application: Claudio Spiess (5HN43G3472)"

INSTALL=false
NOTARIZE=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --notarize) NOTARIZE=true ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

echo "==> swift build -c release"
swift build -c release

APP_BUNDLE="dist/${APP_NAME}.app"
rm -rf dist
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APP_BUNDLE}/Contents/Library/LaunchDaemons"

echo "==> Copying executables"
cp ".build/release/${EXECUTABLE_NAME}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"
cp ".build/release/${HELPER_EXECUTABLE_NAME}" "${APP_BUNDLE}/Contents/MacOS/${HELPER_EXECUTABLE_NAME}"

echo "==> Copying privileged helper launchd plist"
cp "Resources/PrivilegedHelper/${HELPER_BUNDLE_ID}.plist" \
    "${APP_BUNDLE}/Contents/Library/LaunchDaemons/${HELPER_BUNDLE_ID}.plist"

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
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright Claudio Spiess.</string>
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

# Sign the helper FIRST, standalone, with an explicit identifier (-i) — a
# bare Mach-O with no Info.plist of its own has no embedded
# CFBundleIdentifier for codesign to infer one from, and the identifier
# must exactly equal ${HELPER_BUNDLE_ID} to match the launchd plist's
# Label/MachServices key and the `helperRequirement` designated-requirement
# string baked into the app (PrivilegedHelperConstants).
echo "==> Codesigning helper: ${HELPER_BUNDLE_ID}"
codesign --force --options runtime --timestamp \
    --sign "${SIGN_IDENTITY}" \
    -i "${HELPER_BUNDLE_ID}" \
    "${APP_BUNDLE}/Contents/MacOS/${HELPER_EXECUTABLE_NAME}"

# Sign the outer app WITHOUT --deep now that the one nested executable is
# already signed individually — --deep would re-walk and re-sign nested
# code with the app's own identity/identifier, clobbering the helper's
# carefully-chosen -i identifier above.
echo "==> Codesigning app: ${BUNDLE_ID}"
codesign --force --options runtime --timestamp \
    --sign "${SIGN_IDENTITY}" \
    "${APP_BUNDLE}"

echo "==> Verifying signatures"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
codesign -d -r- "${APP_BUNDLE}/Contents/MacOS/${HELPER_EXECUTABLE_NAME}"

if [[ "${NOTARIZE}" == "true" ]]; then
    ./notarize.sh "${APP_BUNDLE}"
fi

echo
echo "Built: $(pwd)/${APP_BUNDLE}"
echo
echo "Note: SMAppService LaunchDaemons require an admin to approve them in"
echo "System Settings > General > Login Items & Extensions the first time"
echo "the app registers the helper (first Connect attempt). Apple's docs"
echo "also state apps containing LaunchDaemons must be notarized; pass"
echo "--notarize (one-time setup: ./notarize.sh --store-credentials ...)."

if [[ "${INSTALL}" == "true" ]]; then
    echo "==> Installing to /Applications"
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP_BUNDLE}" /Applications/
    echo "Installed: /Applications/${APP_NAME}.app"
fi
