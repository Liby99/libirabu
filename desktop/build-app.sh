#!/usr/bin/env bash
# Build dist/libirabu.app — a self-contained, double-clickable macOS menu-bar app (arm64, unsigned).
# Bundles: the Swift shell + a Node runtime + the embedded-Postgres binaries + the Next standalone server.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
DIST="$REPO/dist"
APP="$DIST/libirabu.app"
CONTENTS="$APP/Contents"
RT="$CONTENTS/Resources/runtime"          # bundled Node payload
SRV="$RT/server"                          # Next standalone server
VERSION="0.1.0"
NODE_BIN="$(node -e 'console.log(process.execPath)')"

echo "▸ clean"
rm -rf "$DIST"
mkdir -p "$CONTENTS/MacOS" "$RT" "$SRV"

echo "▸ next build (standalone)"
npm run build >/dev/null

echo "▸ assemble Next standalone server → $SRV"
cp -R "$REPO/.next/standalone/." "$SRV/"
mkdir -p "$SRV/.next"
cp -R "$REPO/.next/static" "$SRV/.next/static"
[ -d "$REPO/public" ] && cp -R "$REPO/public" "$SRV/public"
# Belt-and-suspenders: ensure node-ical's full closure is present (standalone tracing misses transitive
# deps of external packages — see next.config.ts).
for p in node-ical rrule-temporal temporal-polyfill temporal-spec "@js-temporal/polyfill" jsbi; do
  if [ -d "$REPO/node_modules/$p" ]; then mkdir -p "$SRV/node_modules/$(dirname "$p")"; rm -rf "$SRV/node_modules/$p"; cp -R "$REPO/node_modules/$p" "$SRV/node_modules/$p"; fi
done

echo "▸ supervisor + migrations + embedded-postgres → $RT"
cp "$REPO/desktop/supervisor.cjs" "$REPO/desktop/db.cjs" "$REPO/desktop/secrets.cjs" "$RT/"
mkdir -p "$RT/prisma"
cp -R "$REPO/prisma/migrations" "$RT/prisma/migrations"
# A clean, production-only install of just embedded-postgres (brings the arm64 PG binaries + pg).
printf '{\n  "name": "libirabu-runtime",\n  "private": true,\n  "dependencies": { "embedded-postgres": "%s" }\n}\n' \
  "$(node -e 'console.log(require("./package.json").dependencies["embedded-postgres"])')" > "$RT/package.json"
( cd "$RT" && npm install --omit=dev --no-audit --no-fund >/dev/null )

echo "▸ bundle Node runtime binary"
cp "$NODE_BIN" "$RT/node"
chmod +x "$RT/node"

echo "▸ compile Swift shell → $CONTENTS/MacOS/libirabu"
swiftc -swift-version 5 -target arm64-apple-macos13 -O -o "$CONTENTS/MacOS/libirabu" "$REPO/desktop/shell/main.swift"

echo "▸ Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>libirabu</string>
  <key>CFBundleDisplayName</key><string>libirabu</string>
  <key>CFBundleIdentifier</key><string>dev.libirabu.app</string>
  <key>CFBundleExecutable</key><string>libirabu</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCalendarsUsageDescription</key><string>libirabu reads your calendars to import events.</string>
</dict>
</plist>
PLIST

echo "▸ done"
SIZE="$(du -sh "$APP" | cut -f1)"
echo "Built: $APP  (${SIZE})"
echo "Run:   open \"$APP\"   (first launch: right-click → Open to bypass Gatekeeper)"
