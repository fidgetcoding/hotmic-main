#!/bin/sh
# Builds Hot Mic, installs it to /Applications, pins it to the Dock (once), and relaunches it.
set -e
cd "$(dirname "$0")/.."
./scripts/bundle.sh "${1:-release}"
osascript -e 'quit app "Hot Mic"' 2>/dev/null || true
sleep 1
rm -rf "/Applications/Hot Mic.app"
ditto ".build/Hot Mic.app" "/Applications/Hot Mic.app"
if ! defaults read com.apple.dock persistent-apps | grep -q "Hot%20Mic.app"; then
  defaults write com.apple.dock persistent-apps -array-add \
    '<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file:///Applications/Hot%20Mic.app/</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>'
  killall Dock
fi
open "/Applications/Hot Mic.app"
echo "installed /Applications/Hot Mic.app"
