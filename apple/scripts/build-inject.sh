#!/bin/sh
# Build libPortholeInject.dylib for macOS and each Simulator platform into
# apple/.build/inject/{macos,iphonesimulator,appletvsimulator,watchsimulator,xrsimulator}/. porthole-mcp's attach and
# launch {inject: true} load it from there (or from $PORTHOLE_MCP_INJECT_DIR).
set -eu
cd "$(dirname "$0")/.."
out=.build/inject
mkdir -p "$out/macos"

swift build -c debug --product PortholeInject
cp .build/debug/libPortholeInject.dylib "$out/macos/libPortholeInject.dylib"
codesign -f -s - "$out/macos/libPortholeInject.dylib"

# One injectable build per Simulator platform.
for pair in "iphonesimulator:iOS Simulator" "appletvsimulator:tvOS Simulator" \
            "watchsimulator:watchOS Simulator" "xrsimulator:visionOS Simulator"; do
  dir=${pair%%:*}
  destination=${pair#*:}
  mkdir -p "$out/$dir"
  xcodebuild -scheme PortholeInject -configuration Debug -destination "generic/platform=$destination" \
    -derivedDataPath .build/inject-dd -quiet build
  fw=$(find ".build/inject-dd/Build/Products/Debug-$dir" -name 'PortholeInject.framework' -maxdepth 3 | head -1)
  cp "$fw/PortholeInject" "$out/$dir/libPortholeInject.dylib"
  codesign -f -s - "$out/$dir/libPortholeInject.dylib"
done

echo "built the injectable harness into $out/"
