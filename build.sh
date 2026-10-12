#!/bin/bash
# Builds NotchApp.app into ./build (no Xcode required — Command Line Tools are enough).
#   ./build.sh           release build
#   ./build.sh install   also copy to /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="NotchApp"
BUNDLE_ID="com.notchapp.NotchApp"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
APP="build/$APP_NAME.app"

echo "▸ Compiling Swift…"
mkdir -p build
# A failed build leaves the last good binary in place: stop here rather than package that.
if ! swift build -c release > build/swift-build.log 2>&1; then
  grep -E "error:" build/swift-build.log || tail -20 build/swift-build.log
  echo "✗ Build failed"; exit 1
fi
grep -vE "^\[|Compiling|Write swift-version|Building for|Build complete" build/swift-build.log || true
BIN=".build/release/$APP_NAME"

echo "▸ Compiling media adapter…"
mkdir -p build
clang -dynamiclib -fobjc-arc -O2 -framework Foundation -framework AppKit \
  -arch arm64 -arch x86_64 -mmacosx-version-min=14.2 -w \
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
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>NotchApp's camera mirror shows a preview of yourself before a call.</string>
  <key>NSAppleEventsUsageDescription</key><string>NotchApp's Controls switch Dark Mode and empty the Trash, its app actions read the files selected in Finder and copy the song playing in Spotify, and replies to a coding agent are typed into its own Terminal or iTerm2 tab.</string>
  <key>NSAudioCaptureUsageDescription</key><string>NotchApp's sound mixer adjusts each app's volume by routing its audio through NotchApp, and live captions turn what's playing into text on this Mac.</string>
  <key>NSMicrophoneUsageDescription</key><string>NotchApp turns your side of a call into text on this Mac when you've asked it to transcribe calls, and listens for sounds like a doorbell while you wear headphones if you've turned sound alerts on.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Live captions and call transcripts are turned into text on this Mac.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>NotchApp works out when to leave for events with a place, and shows the Wi-Fi network's name.</string>
  <key>NSContactsUsageDescription</key><string>NotchApp shows today's birthdays from your contacts.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>NotchApp shows today's events and alerts you before meetings.</string>
  <key>NSCalendarsUsageDescription</key><string>NotchApp shows today's events and alerts you before meetings.</string>
  <key>NSDesktopFolderUsageDescription</key><string>NotchApp shows previews of screenshots and files on your shelf.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>NotchApp shows previews of files on your shelf.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>NotchApp shows previews of files on your shelf.</string>
</dict>
</plist>
PLIST

echo "▸ Signing…"
# A stable identity keeps macOS privacy grants (Accessibility, Calendar…) across rebuilds;
# ad-hoc signatures change every build, so macOS asks again each time.
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 -oE '"(Apple Development|Developer ID Application)[^"]*"' | tr -d '"' || true)
codesign --force --deep --sign "${IDENTITY:--}" "$APP" >/dev/null 2>&1
[ -n "$IDENTITY" ] && echo "  signed as $IDENTITY" || echo "  ad-hoc (permissions will reset on each build)"
echo "✓ Built $APP"

if [ "${1:-}" = "install" ]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  open "/Applications/$APP_NAME.app"
  echo "✓ Installed to /Applications and launched"
fi
