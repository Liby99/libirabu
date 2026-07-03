#!/usr/bin/env bash
# Make the persistent server survive reboots: install a LaunchAgent that `open`s Libirabu.app at
# login. It uses `open` (LaunchServices) ON PURPOSE — that keeps the app as the TCC-responsible
# process so the Calendar grant holds. A raw launchd exec of node would NOT inherit that grant.
#
# Run once:  npm run serve:login-item     (also needs Docker Desktop set to "start at login").
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$(pwd)/native/menubar-app/Libirabu.app"
[ -d "$APP" ] || { echo "Build the app first:  bash native/menubar-app/build-app.sh"; exit 1; }

PLIST="$HOME/Library/LaunchAgents/com.libirabu.app.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.libirabu.app</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>${APP}</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "Installed → $PLIST"
echo "Libirabu.app will launch at each login (menu-bar 📅)."
echo "Remove with:  launchctl unload \"$PLIST\" && rm \"$PLIST\""
