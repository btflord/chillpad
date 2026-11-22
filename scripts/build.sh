#!/bin/bash
# Builds build/Chillpad.app (universal). Pass "install" to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Chillpad.app
SDK=$(xcrun --show-sdk-path)
mkdir -p build
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" -sdk "$SDK" Sources/Chillpad/*.swift -o "build/Chillpad-$arch"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
lipo -create build/Chillpad-arm64 build/Chillpad-x86_64 -output "$APP/Contents/MacOS/Chillpad"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp web/pad.html web/denied.html web/icon.png "$APP/Contents/Resources/web/"

# Sign with a real identity if one exists (keeps the Accessibility grant across rebuilds), else ad hoc.
# Prefer Developer ID (needed for notarization), then Apple Development, else ad hoc.
IDS=$(security find-identity -v -p codesigning 2>/dev/null || true)
IDENTITY=$(echo "$IDS" | awk -F'"' '/Developer ID Application/ {print $2; exit}')
[ -n "$IDENTITY" ] || IDENTITY=$(echo "$IDS" | awk -F'"' '/Apple Development/ {print $2; exit}')
TS=--timestamp=none
[[ "$IDENTITY" == Developer\ ID* ]] && TS=--timestamp   # notarization requires a secure timestamp
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime $TS --sign "$IDENTITY" "$APP"
else
  # Ad hoc: an explicit designated requirement keyed on the bundle id keeps the Accessibility
  # grant across rebuilds and updates (a plain ad-hoc signature pins it to this exact build).
  codesign --force --options runtime --sign - --identifier app.chillpad.mac \
    --requirements '=designated => identifier "app.chillpad.mac"' "$APP"
fi
echo "Built $APP (signed: ${IDENTITY:-ad hoc})"

if [ "${1:-}" = "install" ]; then
  pkill -x Chillpad 2>/dev/null || true
  rm -rf /Applications/Chillpad.app
  cp -R "$APP" /Applications/Chillpad.app
  open /Applications/Chillpad.app
  echo "Installed to /Applications/Chillpad.app and launched."
fi
