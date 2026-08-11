#!/bin/bash
# Wraps the SwiftPM release build into a real .app bundle -- SwiftPM
# doesn't produce one natively, and Phase 5 found that camera access
# (and any other TCC-gated capability) hard-requires a bundle with a
# proper Info.plist, not a bare executable.
#
# This produces an AD-HOC SIGNED, UNNOTARIZED bundle for local testing
# only. It is NOT what should ship to real users -- see the "Not done
# here" section in README.md for what Developer ID signing +
# notarization + Sparkle actually require (a paid Apple Developer
# account and real signing infrastructure this environment doesn't have).

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="BookMaster"
BUILD_DIR=".build/release"
APP_BUNDLE="Packaging/${APP_NAME}.app"

echo "==> Building release binary..."
swift build -c release

echo "==> Assembling ${APP_BUNDLE}..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/BookMasterApp" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# SwiftPM writes bundled resources (config.json, books.csv) into a
# sibling .bundle next to the executable; carry it into the app bundle's
# Resources so Bundle.module can still find it at the new relative path.
if [ -d "$BUILD_DIR/BookMasterApp_BookMasterCore.bundle" ]; then
  cp -R "$BUILD_DIR/BookMasterApp_BookMasterCore.bundle" "$APP_BUNDLE/Contents/Resources/"
fi

echo "==> Ad-hoc signing (local testing only, not for distribution)..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
codesign -dv "$APP_BUNDLE" 2>&1 || true
