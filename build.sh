#!/usr/bin/env bash
# Build, bundle, and codesign "Pulse VPN Menu.app".
#
# Usage: ./build.sh            build -> dist/Pulse VPN Menu.app
#        ./build.sh --install  also install to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Pulse VPN Menu"
BUNDLE_ID="com.claudiosv.pulse-vpn-menu"
EXECUTABLE_NAME="PulseVPNMenu"
VERSION="0.1.0"
SIGN_IDENTITY="Developer ID Application: Claudio Spiess (5HN43G3472)"

INSTALL=false
if [[ "${1:-}" == "--install" ]]; then
    INSTALL=true
fi

echo "==> swift build -c release"
swift build -c release

APP_BUNDLE="dist/${APP_NAME}.app"
rm -rf dist
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

echo "==> Copying executable"
cp ".build/release/${EXECUTABLE_NAME}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"

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

echo "==> Codesigning with: ${SIGN_IDENTITY}"
codesign --force --deep --options runtime --timestamp \
    --sign "${SIGN_IDENTITY}" \
    "${APP_BUNDLE}"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

echo
echo "Built: $(pwd)/${APP_BUNDLE}"

if [[ "${INSTALL}" == "true" ]]; then
    echo "==> Installing to /Applications"
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP_BUNDLE}" /Applications/
    echo "Installed: /Applications/${APP_NAME}.app"
fi
