#!/usr/bin/env bash
# Notarize and staple a signed Pulse VPN Menu.app (must be signed with a "Developer ID
# Application" identity — see build.sh). Requires notarization
# credentials already stored under a keychain profile; see --store-credentials
# below for a one-time setup helper.
#
# Usage:
#   ./notarize.sh [path-to-app]                     (default: dist/Pulse VPN Menu.app)
#   ./notarize.sh --store-credentials <key.p8> <key-id> <issuer-id>
#
# The profile name can be overridden with PULSE_NOTARY_PROFILE (default:
# "pulse-vpn-menu-notarytool").
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${PULSE_NOTARY_PROFILE:-pulse-vpn-menu-notarytool}"

if [[ "${1:-}" == "--store-credentials" ]]; then
  KEY_PATH="${2:?usage: notarize.sh --store-credentials <key.p8> <key-id> <issuer-id>}"
  KEY_ID="${3:?usage: notarize.sh --store-credentials <key.p8> <key-id> <issuer-id>}"
  ISSUER_ID="${4:?usage: notarize.sh --store-credentials <key.p8> <key-id> <issuer-id>}"
  echo "▸ Storing notarization credentials under keychain profile \"$PROFILE\"…"
  xcrun notarytool store-credentials "$PROFILE" \
    --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER_ID"
  echo "✓ Stored. Future runs of ./notarize.sh will use this profile."
  exit 0
fi

APP="${1:-$ROOT/dist/Pulse VPN Menu.app}"
if [[ ! -d "$APP" ]]; then
  echo "✗ App bundle not found at $APP" >&2
  exit 1
fi

CODESIGN_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)"
SIGN_AUTHORITY="$(printf '%s\n' "$CODESIGN_INFO" | grep -m1 '^Authority=')"
SIGN_AUTHORITY="${SIGN_AUTHORITY#Authority=}"
if [[ "$SIGN_AUTHORITY" != *"Developer ID Application"* ]]; then
  echo "✗ $APP is not signed with a Developer ID Application identity (found: ${SIGN_AUTHORITY:-none})." >&2
  echo "  Notarization only accepts Developer ID-signed builds. Re-run build.sh once that cert is installed." >&2
  exit 1
fi

ZIP_PATH="$(mktemp -d)/$(basename "$APP" .app).zip"
echo "▸ Zipping $APP for submission…"
ditto -c -k --keepParent "$APP" "$ZIP_PATH"

echo "▸ Submitting to Apple notary service (profile \"$PROFILE\")…"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$PROFILE" --wait

echo "▸ Stapling notarization ticket…"
xcrun stapler staple "$APP"

echo "▸ Validating…"
xcrun stapler validate "$APP"
spctl -a -t exec -vv "$APP"

rm -rf "$(dirname "$ZIP_PATH")"
echo "✓ $APP is notarized and stapled."
