#!/bin/bash
# Open a real Hot Mic session in the design lab.
# Usage: scripts/lab-session.sh "<session folder>"   (default: the newest session in your library)
set -euo pipefail
cd "$(dirname "$0")/.."
LIB="${HOTMIC_LIBRARY:-$HOME/Music/Hot Mic/Sessions}"
[ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Hot Mic/Sessions" ] && LIB="${HOTMIC_LIBRARY:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Hot Mic/Sessions}"
FOLDER="${1:-$(ls -td "$LIB"/*/ 2>/dev/null | head -1)}"
[ -n "$FOLDER" ] && [ -d "$FOLDER" ] || { echo "No session folder found (looked in $LIB)."; exit 1; }
NAME=$(basename "$FOLDER" | tr -c 'A-Za-z0-9-' '-' | sed 's/-*$//')
swift build --product hotmic-export -q
mkdir -p lab/sessions
.build/debug/hotmic-export "$FOLDER" "lab/sessions/$NAME.js"
open "file://$PWD/lab/index.html#session=$NAME"
