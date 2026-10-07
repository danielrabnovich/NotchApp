#!/bin/bash
# Builds NotchApp.app into ./build (no Xcode required — Command Line Tools are enough).
#   ./build.sh           release build
#   ./build.sh install   also copy to /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="NotchApp"
BUNDLE_ID="com.notchapp.NotchApp"
VERSION="1.0.0"
APP="build/$APP_NAME.app"

echo "▸ Compiling Swift…"
swift build -c release 2>&1 | grep -vE "^\[|Compiling|Write swift-version" || true
BIN=".build/release/$APP_NAME"
[ -f "$BIN" ] || { echo "Build failed"; swift build -c release; exit 1; }

echo "▸ Compiling media adapter…"
mkdir -p build
clang -dynamiclib -fobjc-arc -O2 -framework Foundation -framework AppKit \
  -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -w \
  -o build/MediaAdapter.dylib MediaAdapter/MediaAdapter.m

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp build/MediaAdapter.dylib MediaAdapter/adapter.pl "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>NotchApp shows today's events and alerts you before meetings.</string>
  <key>NSCalendarsUsageDescription</key><string>NotchApp shows today's events and alerts you before meetings.</string>
  <key>NSDesktopFolderUsageDescription</key><string>NotchApp shows previews of screenshots and files on your shelf.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>NotchApp shows previews of files on your shelf.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>NotchApp shows previews of files on your shelf.</string>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
echo "✓ Built $APP"

if [ "${1:-}" = "install" ]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  open "/Applications/$APP_NAME.app"
  echo "✓ Installed to /Applications and launched"
fi
