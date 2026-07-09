#!/bin/bash
# Build CalendarMac and wrap it in a minimal .app bundle, then launch it.
#
# A bare SwiftPM executable isn't a macOS .app bundle, so LaunchServices won't
# treat it as a GUI app and the window may never appear. Wrapping it in a bundle
# (Info.plist + Contents/MacOS/) fixes that — no Xcode required.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP=".build/CalendarMac.app"

echo "Building ($CONFIG)..."
swift build -c "$CONFIG" >/dev/null
BIN=".build/$CONFIG/CalendarMac"

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/CalendarMac"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Calendar</string>
  <key>CFBundleDisplayName</key><string>Calendar</string>
  <key>CFBundleExecutable</key><string>CalendarMac</string>
  <key>CFBundleIdentifier</key><string>dev.libirabu.calendar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "Launching..."
open "$APP"
echo "Done. (Relaunch anytime: open $PWD/$APP)"
