#!/bin/bash
# Proves a fresh clone builds, with nothing from this Mac's setup: a new clone, an empty home folder, a bare PATH,
# versions only from Package.resolved. Builds the app bundle and checks what's inside it. It never opens the
# app, never installs anything and never touches /Applications or any audio device.
#
# usage: scripts/verify-clean.sh [work folder] [--with-tests]
set -euo pipefail
SOURCE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-$(mktemp -d)}"
WITH_TESTS=false; [[ "${2:-}" == "--with-tests" ]] && WITH_TESTS=true
fail() { echo "FAILED: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

[[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ]] || echo "note: the clone gets the last commit, not your uncommitted changes"
HEAD="$(git -C "$SOURCE" rev-parse --short HEAD)"
step "clone $HEAD into $WORK"
mkdir -p "$WORK"
[[ ! -e "$WORK/repo" ]] || fail "$WORK/repo already exists"
git clone --quiet --no-hardlinks "$SOURCE" "$WORK/repo"
mkdir -p "$WORK/home"
DEV="$(xcode-select -p)"
clean() { env -i HOME="$WORK/home" PATH=/usr/bin:/bin:/usr/sbin:/sbin DEVELOPER_DIR="$DEV" "$@"; }
cd "$WORK/repo"

step "tools"
clean swift --version 2>&1 | head -1
clean xcrun --show-sdk-version

step "dependencies, exactly as pinned"
cp Package.resolved "$WORK/Package.resolved.before"
clean swift package resolve --force-resolved-versions
cmp Package.resolved "$WORK/Package.resolved.before" || fail "resolving changed Package.resolved"

step "the app bundle, through the same script an install uses"
clean scripts/bundle.sh release
APP="$WORK/repo/.build/Hot Mic.app"
BIN="$APP/Contents/MacOS/HotMic"

step "what's in the bundle"
[[ -x "$BIN" ]] || fail "no executable"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "bad Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")" == HotMic ]] || fail "Info.plist names another executable"
for f in Contents/Resources/ui/index.html Contents/Resources/ui/judge.js Contents/Resources/ui/host.js Contents/Resources/HotMic.icns Contents/Resources/ThirdPartyNotices.txt Contents/Frameworks/Sparkle.framework; do
  [[ -e "$APP/$f" ]] || fail "missing $f"
done
ls "$APP"/Contents/Resources/*.bundle >/dev/null 2>&1 || fail "no resource bundles (the melody model lives in one)"
find "$APP" -name 'nmp.mlmodelc' | grep -q . || fail "no melody model"
[[ -z "$(find "$APP" -name node_modules -o -name '*.test.mjs' -o -name sessions)" ]] || fail "test or session files in the bundle"
otool -l "$BIN" | grep -q '@executable_path/../Frameworks' || fail "no rpath to the embedded frameworks"
for lib in $(otool -L "$BIN" | awk 'NR>1 {print $1}'); do
  case "$lib" in
    /System/*|/usr/lib/*|@rpath/Sparkle.framework/*) ;;
    *) fail "links something a clean Mac may not have: $lib" ;;
  esac
done
if otool -L "$BIN" | grep -q FoundationModels; then
  otool -l "$BIN" | grep -B2 FoundationModels | grep -q LC_LOAD_WEAK_DYLIB || fail "FoundationModels must be weak-linked, or the app won't launch before macOS 26"
fi
minos="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
echo "runs on macOS $minos and up"
[[ "$minos" == 14.2* ]] || fail "expected macOS 14.2, got $minos"
codesign --verify --deep --strict "$APP" || fail "signature doesn't verify"
du -sh "$APP" | awk '{print "bundle size: " $1}'
shasum -a 256 "$BIN" | awk '{print "executable sha256: " $1}'

if $WITH_TESTS; then
  step "tests (the ones that need the mic, the network or local files stay skipped)"
  clean swift test --force-resolved-versions 2>&1 | grep -E " error: |Executed [0-9]+ tests|failed" | tail -5
fi

printf '\nOK: a fresh clone of %s builds a complete, signed (ad hoc) bundle. Not installed, not opened.\n' "$HEAD"
