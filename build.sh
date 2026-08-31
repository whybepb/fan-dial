#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

# This toolchain defaults to a minos newer than the host OS — pin it.
TARGET="arm64-apple-macos14.0"

echo "▸ building fanctl"
swiftc -O -target "$TARGET" shared/SMCCore.swift cli/main.swift -o fanctl -framework IOKit

echo "▸ building FanDial.app"
APP=FanDial.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/Info.plist "$APP/Contents/Info.plist"
swiftc -O -target "$TARGET" -parse-as-library \
    shared/SMCCore.swift \
    app/FanController.swift \
    app/DialView.swift \
    app/FanDialApp.swift \
    -o "$APP/Contents/MacOS/FanDial" \
    -framework IOKit
cp fanctl "$APP/Contents/Resources/fanctl"
codesign --force --sign - "$APP" 2>/dev/null

echo "✓ done — run with:  open $APP"
