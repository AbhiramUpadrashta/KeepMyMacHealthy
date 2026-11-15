#!/bin/bash
# Builds KeepMyMacHealthy.app (universal) with the Swift command line tools — no Xcode project needed.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/KeepMyMacHealthy.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
FW="-framework AppKit -framework SwiftUI -framework IOKit -framework ServiceManagement -framework CryptoKit -framework Security -framework UserNotifications -framework CoreServices -framework ImageIO"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos14.0" -module-name KeepMyMacHealthy \
    Sources/KMH/*.swift $FW -o "build/KMH-$arch"
done
lipo -create build/KMH-arm64 build/KMH-x86_64 -output "$APP/Contents/MacOS/KeepMyMacHealthy"
cp Resources/Info.plist "$APP/Contents/"
ICON=build/AppIcon.iconset; mkdir -p "$ICON"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICON/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICON/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICON" -o "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
