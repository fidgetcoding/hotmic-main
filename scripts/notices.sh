#!/bin/sh
# Regenerates Resources/ThirdPartyNotices.txt from the real license files of every dependency.
set -e
cd "$(dirname "$0")/.."
OUT=Resources/ThirdPartyNotices.txt
{
  echo "Hot Mic by blue gum — third-party software. Full license texts follow."
  echo
  section() { echo "================================================================"; echo "$1"; echo "$2"; echo "----------------------------------------------------------------"; cat "$3"; echo; }
  section "WhisperKit (argmax-oss-swift)" "https://github.com/argmaxinc/argmax-oss-swift" .build/checkouts/argmax-oss-swift/LICENSE
  section "Argmax OSS third-party notices (incl. Hugging Face swift-transformers, Apache-2.0)" "https://github.com/argmaxinc/argmax-oss-swift" .build/checkouts/argmax-oss-swift/NOTICES
  section "Sparkle" "https://github.com/sparkle-project/Sparkle" .build/checkouts/Sparkle/LICENSE
  section "swift-argument-parser" "https://github.com/apple/swift-argument-parser" .build/checkouts/swift-argument-parser/LICENSE.txt
  section "signalsmith-stretch" "https://github.com/Signalsmith-Audio/signalsmith-stretch" Sources/CStretch/vendor/stretch/LICENSE.txt
  section "signalsmith-linear" "https://github.com/Signalsmith-Audio/linear" Sources/CStretch/vendor/linear/LICENSE.txt
  section "Basic Pitch model, Spotify (ICASSP 2022; Core ML model + note extraction ported to Swift)" "https://github.com/spotify/basic-pitch" Sources/Enrichment/Models/BASIC-PITCH-LICENSE.txt
  echo "================================================================"
  echo "OpenAI Whisper model weights (downloaded at first use via WhisperKit's Core ML conversions)"
  echo "https://github.com/openai/whisper — MIT License, Copyright (c) 2022 OpenAI"
  echo
  echo "================================================================"
  echo "Texture photos in the window: CC0 (public domain), sources in lab/textures/CREDITS.md"
  echo
  font() { section "$1 (font, bundled in the window's UI)" "$2" "lab/fonts/licenses/$3-LICENSE.txt"; }
  font "Geist" "https://github.com/vercel/geist-font" geist
  font "Geist Mono" "https://github.com/vercel/geist-font" geist-mono
  font "Space Grotesk" "https://github.com/floriankarsten/space-grotesk" space-grotesk
  font "Archivo" "https://github.com/Omnibus-Type/Archivo" archivo
  font "Archivo Narrow" "https://github.com/Omnibus-Type/ArchivoNarrow" archivo-narrow
  font "Caveat" "https://github.com/googlefonts/caveat" caveat
  font "Fraunces" "https://github.com/undercasetype/Fraunces" fraunces
  font "Instrument Serif" "https://github.com/Instrument/instrument-serif" instrument-serif
  font "IBM Plex Mono" "https://github.com/IBM/plex" ibm-plex-mono
  font "Share Tech Mono" "https://fonts.google.com/specimen/Share+Tech+Mono" share-tech-mono
  font "Righteous" "https://fonts.google.com/specimen/Righteous" righteous
  font "Yellowtail" "https://fonts.google.com/specimen/Yellowtail" yellowtail
} > "$OUT"
echo "wrote $OUT ($(wc -l < "$OUT") lines)"
