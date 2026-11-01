#!/bin/sh
# Spike 0 fixture: records mic + DAW audio, then benches echo cancellation.
# usage: spikes/record-fixture.sh <name> [seconds] [--global]
#   0–8 s: let the beat play, DON'T sing.  8 s → end: hum/sing over it.
set -e
H="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:?name, e.g. laptop-speakers}"; SECS="${2:-30}"; shift; shift 2>/dev/null || true
OUT="$H/../fixtures/spike0/$NAME"
mkdir -p "$OUT"
echo "Play your loud beat in the DAW now. Recording starts in 3 s — stay quiet until the 8 s mark."
sleep 3
"$H/capture/hm-capture" --out "$OUT" --seconds "$SECS" "$@"
cd "$H/aec" && uv run bench.py "$OUT" --music-only 8
echo "Listen: open $OUT/bench"
