#!/bin/bash
# Installs the latest Chillpad release into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/btflord/chillpad/main/install.sh | bash
#
# Files downloaded with curl aren't marked as "downloaded from the internet", so macOS
# doesn't show the unverified-developer warning that a browser download of the DMG gets.
set -euo pipefail

REPO="btflord/chillpad"
APP="/Applications/Chillpad.app"
say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Chillpad runs on macOS only."
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAJOR" -ge 13 ] || fail "Chillpad needs macOS 13 Ventura or later (this Mac has $(sw_vers -productVersion))."

TMP=$(mktemp -d)
MNT="$TMP/mnt"
cleanup() { hdiutil detach -quiet "$MNT" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

say "Finding the latest Chillpad release…"
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
[ -n "$URL" ] || fail "Couldn't find a Chillpad download. Check your internet connection and try again."

say "Downloading $(basename "$URL")…"
curl -fL --progress-bar -o "$TMP/Chillpad.dmg" "$URL"

say "Installing to /Applications…"
mkdir -p "$MNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$TMP/Chillpad.dmg"
codesign --verify --deep --strict "$MNT/Chillpad.app" 2>/dev/null || fail "The downloaded app failed its integrity check. Nothing was installed."

if pgrep -x Chillpad >/dev/null; then osascript -e 'quit app "Chillpad"' 2>/dev/null || pkill -x Chillpad || true; sleep 1; fi
if [ -w /Applications ]; then
  rm -rf "$APP"; cp -R "$MNT/Chillpad.app" "$APP"
else
  say "Your password is needed to write to /Applications."
  sudo rm -rf "$APP"; sudo cp -R "$MNT/Chillpad.app" "$APP"
fi

open "$APP"
say "Done. Chillpad is in your menu bar."
echo "Allow Accessibility when macOS asks, then scan the QR code with your iPhone."
