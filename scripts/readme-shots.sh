#!/bin/zsh
# Renders the README screenshots into docs/screenshots with demo data.
# Runs a copy of the app with its own bundle id and data folder, so your real
# settings, notes and clipboard history are never touched.
set -e
cd "$(dirname "$0")/.."
./build.sh >/dev/null
TMP=$(mktemp -d)
cp -R MacIsland.app "$TMP/Shots.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.macisland.readme-shots" "$TMP/Shots.app/Contents/Info.plist"
codesign --force --sign - "$TMP/Shots.app" >/dev/null 2>&1
mkdir -p "$TMP/data"
MACISLAND_SUPPORT_DIR="$TMP/data" "$TMP/Shots.app/Contents/MacOS/MacIsland" \
  --readme-shots "$PWD/docs/screenshots" -AppleLanguages "(en)"
defaults delete app.macisland.readme-shots >/dev/null 2>&1 || true
rm -rf "$TMP"


# Settings: keep only the right pane (the sidebar selection doesn't render off-screen)
for f in docs/screenshots/settings*.png; do
  sips -c 1144 1040 --cropOffset 0 480 "$f" >/dev/null
done
sips -c 640 1040 --cropOffset 0 0 docs/screenshots/settings-music.png >/dev/null

# App icon → Resources/AppIcon.icns
ICON=docs/screenshots/icon.png
SET=$(mktemp -d)/AppIcon.iconset; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICON" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
mkdir -p docs && sips -z 256 256 "$ICON" --out docs/icon.png >/dev/null && rm "$ICON"
echo "Screenshots: docs/screenshots, icon: Resources/AppIcon.icns"
