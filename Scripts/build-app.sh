#!/usr/bin/env bash
# Builds Buckets.app into ./build. Usage: Scripts/build-app.sh [debug|release]
# Signs with SIGN_IDENTITY if set, else your Apple Development certificate if you have one, else ad hoc.
# A stable certificate keeps the Keychain's "Always Allow" across rebuilds; ad hoc builds are asked again.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Buckets.app"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Rendering app icon…"
rm -rf build/AppIcon.iconset
mkdir -p build
"$BIN_DIR/Buckets" --render-icon build/AppIcon.iconset >/dev/null
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Buckets" "$APP/Contents/MacOS/Buckets"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "▸ Signing ($SIGN_IDENTITY)…"
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP" >/dev/null
elif DEV_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}') && [[ -n "$DEV_IDENTITY" ]]; then
    echo "▸ Signing ($DEV_IDENTITY)…"
    codesign --force --sign "$DEV_IDENTITY" --options runtime --timestamp=none "$APP" >/dev/null
else
    echo "▸ Signing (ad hoc)…"
    codesign --force --sign - --timestamp=none "$APP" >/dev/null
fi

echo "✓ Built $(pwd)/$APP"
