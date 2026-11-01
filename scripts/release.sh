#!/bin/bash
# Hot Mic release: build → Developer ID sign (hardened runtime) → notarize → staple → DMG → appcast.
#
# One-time setup on the release Mac:
#   1. Install your "Developer ID Application" certificate (Xcode → Settings → Accounts → Manage Certificates).
#   2. xcrun notarytool store-credentials hotmic-notary --apple-id <you> --team-id <TEAMID>
#   3. Sparkle signing key: .build/artifacts/sparkle/Sparkle/bin/generate_keys   (prints SPARKLE_PUBLIC_KEY)
#
# usage: DEVELOPER_ID="Developer ID Application: Lorecraft LLC (TEAMID)" \
#        NOTARY_PROFILE=hotmic-notary \
#        SU_FEED_URL=https://<your-site>/hotmic/appcast.xml SPARKLE_PUBLIC_KEY=<key> \
#        scripts/release.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
: "${DEVELOPER_ID:?set DEVELOPER_ID to your 'Developer ID Application: …' identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE (xcrun notarytool store-credentials)}"
security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID" \
  || { echo "release: signing identity not found in keychain: $DEVELOPER_ID" >&2; exit 1; }

DIST="dist/$VERSION"
APP=".build/Hot Mic.app"
rm -rf "$DIST"; mkdir -p "$DIST"

# 1. Build + assemble (ad-hoc signed first; re-signed below).
scripts/bundle.sh release
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$PLIST"
if [[ -n "${SU_FEED_URL:-}" && -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SU_FEED_URL" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$PLIST"
else
  echo "release: SU_FEED_URL / SPARKLE_PUBLIC_KEY not set — this build won't auto-update" >&2
fi

# 2. Sign inside-out: Sparkle's helpers, then frameworks, then the app.
SIGN=(codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID")
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  for item in "$SPARKLE"/Versions/B/XPCServices/*.xpc "$SPARKLE"/Versions/B/Autoupdate "$SPARKLE"/Versions/B/Updater.app; do
    [[ -e "$item" ]] && "${SIGN[@]}" "$item"
  done
  "${SIGN[@]}" "$SPARKLE"
fi
"${SIGN[@]}" --entitlements Resources/HotMic.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 3. Notarize + staple the app.
ditto -c -k --keepParent "$APP" "$DIST/HotMic.zip"
xcrun notarytool submit "$DIST/HotMic.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

# 4. DMG (signed, notarized, stapled).
STAGE="$DIST/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Hot Mic" -srcfolder "$STAGE" -ov -format UDZO "$DIST/HotMic-$VERSION.dmg"
rm -rf "$STAGE"
"${SIGN[@]}" "$DIST/HotMic-$VERSION.dmg"
xcrun notarytool submit "$DIST/HotMic-$VERSION.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DIST/HotMic-$VERSION.dmg"
spctl --assess --type open --context context:primary-signature --verbose "$DIST/HotMic-$VERSION.dmg"

# 5. Sparkle appcast (upload dist/<version>/ contents to wherever SU_FEED_URL points).
GEN=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [[ -x "$GEN" && -n "${SU_FEED_URL:-}" ]]; then
  "$GEN" "$DIST"
fi
echo "release: $DIST/HotMic-$VERSION.dmg"
