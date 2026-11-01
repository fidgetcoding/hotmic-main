#!/bin/sh
# Builds Hot Mic.app (ad-hoc signed) into .build/Hot Mic.app.
# Ad-hoc signed, no hardened runtime (it rejects ad-hoc frameworks); scripts/release.sh signs
# with Developer ID + hardened runtime for notarized builds.
set -e
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product HotMic   # only the app (other products pull TTSKit, which fails to compile)
APP=".build/Hot Mic.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/HotMic" "$APP/Contents/MacOS/HotMic"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/ThirdPartyNotices.txt "$APP/Contents/Resources/"
cp Resources/HotMic.icns Resources/Icon/menubar-off.svg Resources/Icon/menubar-on.svg "$APP/Contents/Resources/"
# The Hot Mic window's UI (the design lab, run in app mode). Real sessions and dev pages stay out.
rsync -a --exclude sessions/ --exclude '*.bak' --exclude logo.html --exclude icon.html --exclude flame.html --exclude flame-base.svg --exclude brand.html --exclude brand/ --exclude brand-icon-contact-sheet.png --exclude flame-fit.html --exclude flame-border.html --exclude accents.html lab/ "$APP/Contents/Resources/ui/"
# SwiftPM resource bundles (Basic Pitch model, etc.) live in Resources, where the code looks first.
for b in .build/"$CONFIG"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# Embedded frameworks (Sparkle) — the executable looks in @executable_path/../Frameworks.
mkdir -p "$APP/Contents/Frameworks"
for fw in .build/"$CONFIG"/*.framework; do [ -e "$fw" ] && cp -R "$fw" "$APP/Contents/Frameworks/"; done
# Ad-hoc (-) by default. Ad-hoc changes the code hash every build, so macOS asks for the mic again and the
# first session after a rebuild records nothing; set HOTMIC_SIGN_ID to a local signing identity to keep the grants.
SIGN_ID="${HOTMIC_SIGN_ID:--}"
for fw in "$APP"/Contents/Frameworks/*.framework; do [ -e "$fw" ] && codesign --force --sign "$SIGN_ID" "$fw"; done
codesign --force --sign "$SIGN_ID" \
  --entitlements Resources/HotMic.entitlements "$APP"
echo "built $(pwd)/$APP"
