#!/bin/sh
# Builds Hot Mic, installs it to /Applications, pins it to the Dock (once), and relaunches it.
set -e
cd "$(dirname "$0")/.."
./scripts/bundle.sh "${1:-release}"
osascript -e 'quit app "Hot Mic"' 2>/dev/null || true
# It finishes a session's files before it goes: never swap the app out from under that.
for _ in $(seq 1 120); do pgrep -x HotMic >/dev/null || break; sleep 1; done
if pgrep -x HotMic >/dev/null; then echo "Hot Mic is still running after 2 minutes; nothing was replaced. Quit it and run this again." >&2; exit 1; fi
rm -rf "/Applications/Hot Mic.app"
ditto ".build/Hot Mic.app" "/Applications/Hot Mic.app"
if ! defaults read com.apple.dock persistent-apps | grep -q "Hot%20Mic.app"; then
  defaults write com.apple.dock persistent-apps -array-add \
    '<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file:///Applications/Hot%20Mic.app/</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>'
  killall Dock
fi
open "/Applications/Hot Mic.app"
echo "installed /Applications/Hot Mic.app"
