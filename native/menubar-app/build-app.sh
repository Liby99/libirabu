#!/usr/bin/env bash
# Build Libirabu.app — the menu-bar agent that hosts the Next.js server and opens it in your browser
# (docs §5.2). Harness version: uses your installed Node (baked in at build time); a later step
# bundles Node + a Next standalone build for a fully self-contained /Applications app.
#
# Launch it the LaunchServices way (so it's the TCC-responsible process):  open native/menubar-app/Libirabu.app
set -euo pipefail
cd "$(dirname "$0")"

REPO=$(cd ../.. && pwd)
APP="Libirabu.app"
BIN="Libirabu"
NODE="$(command -v node || true)"; [ -n "$NODE" ] || NODE="/opt/homebrew/bin/node"
# Resolve symlinks to a STABLE path — fnm/nvm put `node` behind an ephemeral per-shell symlink
# that disappears when the shell closes; the app (launched much later) needs the real target.
NODE="$(python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$NODE" 2>/dev/null || echo "$NODE")"
[ -x "$NODE" ] || { echo "node not found/executable at: $NODE"; exit 1; }

echo "node:    $NODE"
echo "project: $REPO"
echo "compiling..."
swiftc -O main.swift -o "$BIN"

echo "assembling ${APP}..."
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS"
cp "$BIN" "${APP}/Contents/MacOS/${BIN}"

cat > "${APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.libirabu.app</string>
  <key>CFBundleName</key><string>Libirabu</string>
  <key>CFBundleExecutable</key><string>Libirabu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSCalendarsUsageDescription</key><string>libirabu reads your calendars to import events.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>libirabu reads your calendars to import events.</string>
  <key>LibirabuProjectDir</key><string>${REPO}</string>
  <key>LibirabuNode</key><string>${NODE}</string>
</dict>
</plist>
EOF

codesign --force --sign - --identifier com.libirabu.app "$APP"
echo ""
echo "built: $(pwd)/${APP}"
echo "run:   open $(pwd)/${APP}    then click the menu-bar 📅 → Open My Calendar"
