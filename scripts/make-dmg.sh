#!/bin/bash
# Builds build/Chillpad-<version>.dmg: a drag-to-Applications disk image with the universal app.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" packaging/Info.plist)
NAME="Chillpad"
STAGE=build/dmg
RW=build/$NAME-rw.dmg
OUT=build/$NAME-$VERSION.dmg
W=540; H=400

rm -rf "$STAGE" "$RW" "$OUT"
mkdir -p "$STAGE/.background"
cp -R build/$NAME.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp packaging/dmg-readme.txt "$STAGE/If macOS blocks Chillpad.txt"
swift scripts/make-dmg-background.swift "$STAGE/.background/bg1x.png" $W $H 1
swift scripts/make-dmg-background.swift "$STAGE/.background/bg2x.png" $W $H 2
# One TIFF holding both resolutions, so the background is sharp on Retina screens.
tiffutil -cathidpicheck "$STAGE/.background/bg1x.png" "$STAGE/.background/bg2x.png" -out "$STAGE/.background/bg.tiff" >/dev/null
rm "$STAGE"/.background/bg*x.png

# Writable image first, so Finder can save the window layout into it.
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/Apple_HFS/ {print $1}')
MNT="/Volumes/$NAME"
sleep 1

# Window layout (needs Finder automation permission the first time; the DMG still works without it).
if ! osascript <<EOF
tell application "Finder"
  tell disk "$NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, $((200 + W)), $((120 + H + 28))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set text size of opts to 13
    set background picture of opts to file ".background:bg.tiff"
    set position of item "$NAME.app" of container window to {150, 140}
    set position of item "Applications" of container window to {390, 140}
    set position of item "If macOS blocks Chillpad.txt" of container window to {270, 258}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
then
  echo "! Finder layout skipped (no automation permission). The DMG still installs normally."
fi

# Volume icon = app icon.
cp packaging/AppIcon.icns "$MNT/.VolumeIcon.icns"
SetFile -a C "$MNT" 2>/dev/null || true
chmod -Rf go-w "$MNT" 2>/dev/null || true
rm -rf "$MNT/.fseventsd"
sync
hdiutil detach -quiet "$DEV" || { sleep 2; hdiutil detach -force -quiet "$DEV"; }

hdiutil convert -quiet "$RW" -format ULFO -o "$OUT"
rm -f "$RW"
rm -rf "$STAGE"

# Signing the disk image only helps with a Developer ID. A signed but unnotarized image is
# checked by Gatekeeper when it's opened and gets the "could not verify" warning, while an
# unsigned image just opens. So: Developer ID → sign, notarize and staple; otherwise leave it unsigned.
DEVID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [ -n "$DEVID" ]; then
  codesign --force --timestamp --sign "$DEVID" "$OUT"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    # One-time setup: xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
    xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT"
    echo "Notarized and stapled."
  else
    echo "! Signed with $DEVID but not notarized. Set NOTARY_PROFILE to notarize."
  fi
fi
echo "Built $OUT ($(du -h "$OUT" | cut -f1 | xargs))"
