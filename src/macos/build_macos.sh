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
# (checks the standard Homebrew locations directly, because 'bash script.sh' started
#  from zsh doesn't always have /opt/homebrew/bin in its PATH)
if [ -z "${QT_DIR:-}" ]; then
    for candidate in /opt/homebrew/opt/qt@5 /usr/local/opt/qt@5; do
        if [ -x "$candidate/bin/qmake" ]; then QT_DIR="$candidate"; break; fi
    done
fi
if [ -z "${QT_DIR:-}" ] && command -v brew >/dev/null 2>&1; then
    QT_DIR="$(brew --prefix qt@5 2>/dev/null || true)"
fi
if [ -z "${QT_DIR:-}" ] || [ ! -x "$QT_DIR/bin/qmake" ]; then
    echo "Qt 5 not found. Install it with 'brew install qt@5' or set QT_DIR=/path/to/qt@5" >&2
    exit 1
fi

# --- check that this is the complete source tree, not only the changed files ---------
if [ ! -f "$SRC_DIR/core/MainController.cpp" ] || [ ! -d "$SRC_DIR/qml" ]; then
    echo "The full Luminosus source is missing next to $SCRIPT_DIR." >&2
    echo "Download/clone https://github.com/xhpohanka/LuminosusEosEdition and unzip the" >&2
    echo "changed files over it (so src/macos sits inside that repo's src folder)." >&2
    exit 1
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

# --- copy libraries macdeployqt misses ----------------------------------------------
# macdeployqt doesn't follow "@rpath/..." dependencies of Homebrew libraries, e.g.
# libfreetype -> libbrotlidec -> @rpath/libbrotlicommon. A missing one stops the cocoa
# platform plugin from loading ("could not find or load the Qt platform plugin").
HB_PREFIX="$(cd "$QT_DIR/../.." && pwd)"   # /opt/homebrew or /usr/local
FW="$APP/Contents/Frameworks"
changed=1
while [ "$changed" -eq 1 ]; do
    changed=0
    while IFS= read -r -d '' bin; do
        file "$bin" | grep -q "Mach-O" || continue
        # dependencies that are only resolvable inside Homebrew
        for dep in $(otool -L "$bin" | tail -n +2 | awk '{print $1}' | grep -E "^(@rpath/|$HB_PREFIX/)" | grep -v "\.framework/"); do
            name="$(basename "$dep")"
            if [ ! -e "$FW/$name" ]; then
                src="$HB_PREFIX/lib/$name"
                [ -e "$src" ] || src="$(find "$HB_PREFIX/opt" -maxdepth 3 -name "$name" 2>/dev/null | head -1)"
                if [ -z "$src" ] || [ ! -e "$src" ]; then
                    echo "WARNING: $name (needed by $(basename "$bin")) not found in Homebrew" >&2
                    continue
                fi
                echo "Bundling missing library: $name"
                cp -L "$src" "$FW/$name"
                chmod u+w "$FW/$name"
                install_name_tool -id "@rpath/$name" "$FW/$name" 2>/dev/null
                changed=1
            fi
            # point absolute Homebrew paths at the bundled copy
            if [[ "$dep" == "$HB_PREFIX"/* ]]; then
                install_name_tool -change "$dep" "@executable_path/../Frameworks/$name" "$bin" 2>/dev/null
            fi
        done
    done < <(find "$APP/Contents" -type f \( -name "*.dylib" -o -path "*/MacOS/*" -o -path "*.framework/Versions/*" \) -print0)
done

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
