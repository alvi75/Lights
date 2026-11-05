#!/usr/bin/env bash
# Build Lights.app — a real macOS .app bundle, double-clickable from Finder.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Lights"
APP_DIR="$APP_NAME.app"
EXEC_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

if [ ! -f Resources/AppIcon.icns ]; then
    echo "→ Rendering app icon..."
    swift tools/render-icon.swift
    iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
fi

echo "→ Compiling release binary..."
log=$(mktemp -t lights-build)
trap 'rm -f "$log"' EXIT
if ! swift build -c release --arch arm64 --product Lights >"$log" 2>&1; then
    # Command Line Tools ship the macOS 27 SDK without SwiftUI's macro plugin (Xcode
    # has it), so @State fails to build. An older SDK from the same tools still works.
    sdk=""
    if grep -q "plugin for module 'SwiftUIMacros' not found" "$log"; then
        sdk=$(ls -d "$(xcode-select -p)"/SDKs/MacOSX2[0-6].*sdk "$(xcode-select -p)"/SDKs/MacOSX2[0-6].sdk 2>/dev/null | sort -V | tail -n 1)
    fi
    if [ -z "$sdk" ]; then
        cat "$log"
        exit 1
    fi
    echo "  SwiftUI macros missing from this SDK; building with $(basename "$sdk")"
    SDKROOT="$sdk" swift build -c release --arch arm64 --product Lights
fi

echo "→ Assembling $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$EXEC_DIR" "$RES_DIR"
cp .build/release/$APP_NAME "$EXEC_DIR/$APP_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$RES_DIR/AppIcon.icns"

echo "→ Code-signing (ad-hoc)..."
codesign --force --deep --entitlements Resources/Lights.entitlements --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "✓ Built $APP_DIR"
echo "  Run:     open $APP_DIR"
echo "  Install: mv $APP_DIR /Applications/"
