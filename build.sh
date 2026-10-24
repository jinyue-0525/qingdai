#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${QINGDAI_OUTPUT_DIR:-$(dirname "$PROJECT_DIR")}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qingdai-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

# swift build compiles only; it does not launch the app or run tests.
xcrun swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR/package" --configuration release
BIN_DIR="$(xcrun swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR/package" --configuration release --show-bin-path)"
APP_DIR="$BUILD_DIR/轻待.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/QingDai" "$APP_DIR/Contents/MacOS/QingDai"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
xcrun swift "$PROJECT_DIR/Resources/MakeIcon.swift" "$BUILD_DIR/AppIcon.iconset"
iconutil --convert icns "$BUILD_DIR/AppIcon.iconset" --output "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_DIR"
mkdir -p "$OUTPUT_DIR"
ditto "$APP_DIR" "$OUTPUT_DIR/轻待.app"
echo "已生成：$OUTPUT_DIR/轻待.app"
