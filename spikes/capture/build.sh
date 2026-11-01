#!/bin/sh
# Builds hm-capture with an embedded Info.plist (needed for mic + audio-capture permission prompts).
set -e
cd "$(dirname "$0")"
swiftc -O -swift-version 5 main.swift -o hm-capture \
  -framework AppKit -framework AVFoundation -framework CoreAudio \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
codesign --force --sign - --identifier io.bluegum.hotmic.spike-capture hm-capture
echo "built $(pwd)/hm-capture"
