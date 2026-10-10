#!/bin/bash
# Build, bundle, sign and package Luminosus for current macOS versions.
#
# Requirements (once):
#   xcode-select --install          # Apple command line tools (clang, SDK)
#   brew install qt@5               # Qt 5.15.x, native for Apple Silicon and Intel
#
# Usage (from anywhere):
#   ./src/macos/build_macos.sh
#
# Optional: sign with your Developer ID instead of ad-hoc:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./src/macos/build_macos.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$SRC_DIR/.." && pwd)"
BUILD_DIR="$REPO_DIR/build-macos"
APP="$BUILD_DIR/luminosus.app"
ENTITLEMENTS="$SCRIPT_DIR/luminosus.entitlements"

# --- locate Qt 5 ---------------------------------------------------------------
if [ -z "${QT_DIR:-}" ]; then
    if command -v brew >/dev/null 2>&1 && brew --prefix qt@5 >/dev/null 2>&1; then
        QT_DIR="$(brew --prefix qt@5)"
    else
        echo "Qt 5 not found. Install it with 'brew install qt@5' or set QT_DIR=/path/to/Qt/5.15.x/clang_64" >&2
        exit 1
    fi
fi
QMAKE="$QT_DIR/bin/qmake"
MACDEPLOYQT="$QT_DIR/bin/macdeployqt"
echo "Using Qt: $("$QMAKE" -query QT_VERSION) from $QT_DIR"

# --- build -----------------------------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
"$QMAKE" "$SRC_DIR/luminosus.pro" CONFIG+=release CONFIG-=debug
make -j"$(sysctl -n hw.ncpu)"

# --- bundle Qt frameworks and QML plugins into the .app ---------------------------
"$MACDEPLOYQT" "$APP" -qmldir="$SRC_DIR/qml" -always-overwrite

# --- sanity check: the privacy keys must be in the final bundle --------------------
for key in NSMicrophoneUsageDescription NSAudioCaptureUsageDescription; do
    if ! /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
        echo "ERROR: $key missing from $APP/Contents/Info.plist" >&2
        exit 1
    fi
done

# --- sign ---------------------------------------------------------------------------
xattr -cr "$APP"
if [ -n "${SIGN_IDENTITY:-}" ]; then
    # Developer ID + hardened runtime (needed for notarization / distribution)
    codesign --force --deep --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
else
    # Ad-hoc signature: fine for use on your own Macs.
    # (No hardened runtime here: it would block loading the ad-hoc signed Qt plugins.)
    codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi
codesign --verify --deep --strict --verbose=1 "$APP"

# --- package -----------------------------------------------------------------------
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$BUILD_DIR/luminosus-${VERSION}-macos-$(uname -m).dmg"
hdiutil create -volname "Luminosus" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null

echo
echo "Done:"
echo "  App: $APP"
echo "  DMG: $DMG"
