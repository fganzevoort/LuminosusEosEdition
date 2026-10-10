#!/bin/bash
# Quick fix for the existing Luminosus 1.3.1 build (no compiling needed).
# Adds the missing microphone usage description to the app's Info.plist and re-signs
# it ad-hoc, so macOS can show the permission prompt and audio inputs deliver sound.
#
# Usage:
#   ./patch_existing_app.sh /Applications/luminosus.app
#
# Notes:
# - Copy the app out of the DMG first (DMG volumes are read-only).
# - This fixes external sound cards / microphones. The "System Audio (all apps)" input
#   for QLab / Music needs the rebuilt app (see build_macos.sh), or a loopback driver
#   such as BlackHole with the old app.

set -euo pipefail

APP="${1:-/Applications/luminosus.app}"
PLIST="$APP/Contents/Info.plist"

if [ ! -f "$PLIST" ]; then
    echo "Not found: $PLIST" >&2
    exit 1
fi

set_key() {
    /usr/libexec/PlistBuddy -c "Delete :$1" "$PLIST" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$PLIST"
}

set_key NSMicrophoneUsageDescription "Luminosus analyses audio from your sound card or microphone to drive lighting."
set_key CFBundleIdentifier "org.luminosus.LuminosusEosEdition"

xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --verbose=1 "$APP"

# forget any earlier (broken) permission decision for this app, so macOS asks again
tccutil reset Microphone org.luminosus.LuminosusEosEdition >/dev/null 2>&1 || true

echo "Patched. Start the app; macOS should now ask for microphone access."
