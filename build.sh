#!/bin/zsh
# Builds MacIsland.app without an Xcode project (only the Command Line Tools are needed).
#   ./build.sh          — build
#   ./build.sh install  — build, copy to /Applications and launch
set -e
cd "$(dirname "$0")"

APP=MacIsland.app
VERSION=0.1.0

# Signing: if the keychain has a code-signing certificate named "MacIsland Dev", use it so macOS
# keeps permissions (Accessibility, microphone, folders) across rebuilds. Otherwise sign ad-hoc.
SIGN=$(security find-identity -p codesigning 2>/dev/null | awk '/"MacIsland Dev"/ {print $2; exit}')
SIGN=${SIGN:--}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# FoundationModels (Apple Intelligence) exists only on macOS 26+, Translation on 15+ — link them weakly
# so the app still runs on macOS 14.
xcrun swiftc -swift-version 5 -O \
  -target arm64-apple-macos14.0 \
  $(find Sources -name '*.swift') \
  -Xlinker -weak_framework -Xlinker FoundationModels -Xlinker -weak_framework -Xlinker Translation \
  -o "$APP/Contents/MacOS/MacIsland"

# "Now Playing" bridge (loaded into the system perl, see Helper/NowPlayingHelper.m)
xcrun clang -dynamiclib -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 \
  -framework Foundation Helper/NowPlayingHelper.m \
  -o "$APP/Contents/Resources/MacIslandNowPlaying.dylib"
codesign --force --sign "$SIGN" "$APP/Contents/Resources/MacIslandNowPlaying.dylib" >/dev/null 2>&1 || true

cp -R Resources/*.lproj "$APP/Contents/Resources/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacIsland</string>
  <key>CFBundleDisplayName</key><string>MacIsland</string>
  <key>CFBundleIdentifier</key><string>app.macisland.MacIsland</string>
  <key>CFBundleExecutable</key><string>MacIsland</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>MacIsland listens for voice questions and the music commands “next”, “back” and “pause”.</string>
  <key>NSAppleEventsUsageDescription</key><string>MacIsland controls Spotify and Music when another player (for example a paused video) holds the system media controls.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>MacIsland recognises your voice commands and questions.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN" "$APP" >/dev/null 2>&1 || true
echo "Built: $(pwd)/$APP"

if [[ "$1" == "install" ]]; then
  pkill -x MacIsland 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/MacIsland.app
  cp -R "$APP" /Applications/
  open /Applications/MacIsland.app
  echo "Installed to /Applications/MacIsland.app"
fi
