#!/usr/bin/env bash
# Builds Hot Mic for iPhone (Debug, signed with your team) and installs it on the connected iPhone.
# Usage: DEVELOPMENT_TEAM=ABCDE12345 ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

TEAM="${DEVELOPMENT_TEAM:-}"
if [[ -z "$TEAM" ]]; then
  echo "error: DEVELOPMENT_TEAM isn't set." >&2
  echo "  Find your 10-character Team ID in Xcode › Settings › Accounts, then run:" >&2
  echo "  DEVELOPMENT_TEAM=ABCDE12345 ./install.sh" >&2
  exit 1
fi

command -v xcodegen >/dev/null || { echo "error: xcodegen not found (brew install xcodegen)" >&2; exit 1; }
xcodegen generate

DERIVED="$PWD/build/DerivedData"
xcodebuild -project HotMicRemote.xcodeproj -scheme HotMicRemote -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic build

APP="$DERIVED/Build/Products/Debug-iphoneos/HotMicRemote.app"
[[ -d "$APP" ]] || { echo "error: build finished but $APP is missing" >&2; exit 1; }

# First paired iPhone that's connected (USB or Wi-Fi).
DEVICES_JSON="$(mktemp -t hotmic-devices).json"
trap 'rm -f "$DEVICES_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null
DEVICE="$(/usr/bin/python3 - "$DEVICES_JSON" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
def ok(d):
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    return hw.get("platform") == "iOS" and conn.get("pairingState") == "paired" \
        and conn.get("tunnelState") != "unavailable"
match = next((d for d in devices if ok(d)), None)
print(match["identifier"] if match else "")
PY
)"
if [[ -z "$DEVICE" ]]; then
  echo "error: no connected iPhone found. Plug it in, unlock it, and trust this Mac." >&2
  exit 1
fi

echo "Installing on $DEVICE…"
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "Done. Open Hot Mic on the iPhone."
